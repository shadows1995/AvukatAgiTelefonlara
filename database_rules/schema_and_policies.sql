-- 1) Enable RLS and System Settings Policies
ALTER TABLE system_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Enable read access for all users" ON system_settings
    FOR SELECT USING (true);

CREATE POLICY "Enable update for admins" ON system_settings
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM users
            WHERE users.uid = auth.uid()
            AND users.role = 'admin'
        )
    );

CREATE POLICY "Enable insert for admins" ON system_settings
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM users
            WHERE users.uid = auth.uid()
            AND users.role = 'admin'
        )
    );

-- 2) Function to check daily job limit (Trigger)
CREATE OR REPLACE FUNCTION check_daily_job_limit()
RETURNS TRIGGER AS $$
DECLARE
    job_count INTEGER;
    user_role TEXT;
BEGIN
    SELECT role INTO user_role FROM users WHERE uid = NEW.created_by;
    IF user_role = 'admin' THEN
        RETURN NEW;
    END IF;

    SELECT COUNT(*)
    INTO job_count
    FROM jobs
    WHERE created_by = NEW.created_by
      AND created_at >= CURRENT_DATE
      AND created_at < CURRENT_DATE + INTERVAL '1 day';

    IF job_count >= 10 THEN
        RAISE EXCEPTION 'Günlük görev oluşturma limitine (10) ulaştınız.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tr_check_daily_job_limit ON jobs;
CREATE TRIGGER tr_check_daily_job_limit
BEFORE INSERT ON jobs
FOR EACH ROW
EXECUTE FUNCTION check_daily_job_limit();

-- 3) System Settings Table and Jobs Columns
create table if not exists public.system_settings (
  key text primary key,
  value jsonb not null,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  updated_at timestamp with time zone default timezone('utc'::text, now()) not null
);

alter table public.system_settings enable row level security;

create policy "Allow public read access to system_settings"
  on public.system_settings for select
  using (true);

insert into public.system_settings (key, value)
values ('job_bot_enabled', 'false'::jsonb)
on conflict (key) do nothing;

do $$
begin
    if not exists (select 1 from information_schema.columns where table_name = 'jobs' and column_name = 'owner_name') then
        alter table public.jobs add column owner_name text;
    end if;

    if not exists (select 1 from information_schema.columns where table_name = 'jobs' and column_name = 'owner_phone') then
        alter table public.jobs add column owner_phone text;
    end if;
end $$;

-- 4) Add Billing Info to Users
ALTER TABLE public.users 
ADD COLUMN IF NOT EXISTS billing_address text,
ADD COLUMN IF NOT EXISTS tc_id text,
ADD COLUMN IF NOT EXISTS membership_type text DEFAULT 'free',
ADD COLUMN IF NOT EXISTS membership_start_date TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS membership_end_date TIMESTAMPTZ;

-- 5) Safe Notification Triggers (DB Side)
CREATE TABLE IF NOT EXISTS expiration_notifications_sent (
    job_id UUID PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE,
    notified_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

ALTER TABLE expiration_notifications_sent ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Deny All Access" ON expiration_notifications_sent FOR ALL USING (false) WITH CHECK (false);

CREATE OR REPLACE FUNCTION handle_new_job_notification()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT' AND NEW.status = 'open') THEN
        INSERT INTO notifications (user_id, title, message, type, read, job_id)
        SELECT
            u.uid,
            'Yeni Görev: ' || NEW.courthouse,
            NEW.courthouse || ' adliyesinde yeni bir "' || NEW.job_type || '" görevi açıldı.',
            'info',
            false,
            NEW.id
        FROM users u
        WHERE
            u.preferred_courthouses IS NOT NULL AND
            u.preferred_courthouses @> ARRAY[NEW.courthouse]::text[] AND
            u.uid != NEW.created_by;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_new_job_notification ON jobs;
CREATE TRIGGER trigger_new_job_notification
AFTER INSERT ON jobs
FOR EACH ROW EXECUTE FUNCTION handle_new_job_notification();

CREATE OR REPLACE FUNCTION handle_applicant_selected_notification()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'UPDATE' AND NEW.selected_applicant IS NOT NULL AND NEW.selected_applicant IS DISTINCT FROM OLD.selected_applicant) THEN
        INSERT INTO notifications (user_id, title, message, type, read, job_id)
        VALUES (
            NEW.selected_applicant,
            'Göreve Seçildiniz!',
            'Tebrikler, "' || NEW.title || '" başlıklı göreve seçildiniz.',
            'success',
            false,
            NEW.id
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_applicant_selected_notification ON jobs;
CREATE TRIGGER trigger_applicant_selected_notification
AFTER UPDATE ON jobs
FOR EACH ROW EXECUTE FUNCTION handle_applicant_selected_notification();

CREATE OR REPLACE FUNCTION handle_job_completed_notification()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'UPDATE' AND NEW.status = 'completed' AND OLD.status != 'completed') THEN
        INSERT INTO notifications (user_id, title, message, type, read, job_id)
        VALUES (
            NEW.created_by,
            'Göreviniz Tamamlandı',
            '"' || NEW.title || '" başlıklı göreviniz tamamlandı olarak işaretlendi.',
            'success',
            false,
            NEW.id
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_job_completed_notification ON jobs;
CREATE TRIGGER trigger_job_completed_notification
AFTER UPDATE ON jobs
FOR EACH ROW EXECUTE FUNCTION handle_job_completed_notification();

-- 6) Job Deadline Notification Flag
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS is_deadline_notified BOOLEAN DEFAULT FALSE;

-- 7) Password Complexity Function
CREATE OR REPLACE FUNCTION check_password_complexity(p_password TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    IF LENGTH(p_password) < 6 THEN RETURN FALSE; END IF;
    IF p_password !~ '[A-Za-z]' THEN RETURN FALSE; END IF;
    IF p_password !~ '[0-9]' THEN RETURN FALSE; END IF;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- 9) Duplicate User Check Function
CREATE OR REPLACE FUNCTION check_duplicate_user(check_email TEXT, check_phone TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  email_found BOOLEAN;
  phone_found BOOLEAN;
  clean_phone TEXT;
BEGIN
  clean_phone := regexp_replace(check_phone, '[\s\(\)]', '', 'g');
  SELECT EXISTS (SELECT 1 FROM users WHERE email = check_email) INTO email_found;
  SELECT EXISTS (
    SELECT 1 FROM users 
    WHERE phone = check_phone 
       OR phone = clean_phone
       OR regexp_replace(phone, '[\s\(\)]', '', 'g') = clean_phone
  ) INTO phone_found;

  RETURN jsonb_build_object(
    'email_exists', email_found,
    'phone_exists', phone_found
  );
END;
$$;

-- 10) Unique Constraints on Users
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_email_key') THEN
        ALTER TABLE users ADD CONSTRAINT users_email_key UNIQUE (email);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_phone_key') THEN
        ALTER TABLE users ADD CONSTRAINT users_phone_key UNIQUE (phone);
    END IF;
END $$;

-- 11-12) User Monthly Stats & RLS
CREATE TABLE IF NOT EXISTS user_monthly_stats (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES users(uid) ON DELETE CASCADE,
  month DATE NOT NULL,
  job_count INTEGER DEFAULT 0,
  total_earnings NUMERIC DEFAULT 0,
  jobs_list JSONB DEFAULT '[]'::jsonb,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(user_id, month)
);

CREATE OR REPLACE FUNCTION update_monthly_stats()
RETURNS TRIGGER 
SECURITY DEFINER
AS $$
DECLARE
  job_month DATE;
  job_data JSONB;
  target_user_id UUID;
BEGIN
  IF NEW.status = 'completed' AND OLD.status != 'completed' THEN
    target_user_id := NEW.selected_applicant;
    IF target_user_id IS NULL THEN RETURN NEW; END IF;

    job_month := DATE_TRUNC('month', COALESCE(NEW.completed_at, NOW()))::DATE;
    
    job_data := jsonb_build_object(
      'job_id', NEW.job_id,
      'title', NEW.title,
      'fee', NEW.offered_fee,
      'completed_at', COALESCE(NEW.completed_at, NOW())
    );

    INSERT INTO user_monthly_stats (user_id, month, job_count, total_earnings, jobs_list)
    VALUES (
      target_user_id,
      job_month,
      1,
      COALESCE(NEW.offered_fee, 0),
      jsonb_build_array(job_data)
    )
    ON CONFLICT (user_id, month) DO UPDATE SET
      job_count = user_monthly_stats.job_count + 1,
      total_earnings = user_monthly_stats.total_earnings + EXCLUDED.total_earnings,
      jobs_list = user_monthly_stats.jobs_list || job_data,
      updated_at = NOW();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_monthly_stats ON jobs;
CREATE TRIGGER trigger_update_monthly_stats
AFTER UPDATE ON jobs
FOR EACH ROW
EXECUTE FUNCTION update_monthly_stats();

-- 17) Ratings System
CREATE TABLE IF NOT EXISTS ratings (
    rating_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id UUID NOT NULL REFERENCES jobs(job_id) ON DELETE CASCADE,
    reviewer_id UUID NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
    reviewee_id UUID NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
    rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
    review_text TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(job_id, reviewer_id, reviewee_id)
);

ALTER TABLE jobs ADD COLUMN IF NOT EXISTS owner_rated BOOLEAN DEFAULT FALSE;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS lawyer_rated BOOLEAN DEFAULT FALSE;

CREATE OR REPLACE FUNCTION update_user_average_rating()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE users
    SET rating = (
        SELECT COALESCE(ROUND(AVG(rating)::numeric, 1), 0)
        FROM ratings
        WHERE reviewee_id = NEW.reviewee_id
    )
    WHERE uid = NEW.reviewee_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS update_rating_trigger ON ratings;
CREATE TRIGGER update_rating_trigger
AFTER INSERT ON ratings
FOR EACH ROW
EXECUTE FUNCTION update_user_average_rating();

ALTER TABLE ratings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own ratings"
ON ratings FOR SELECT TO authenticated
USING (auth.uid() = reviewer_id OR auth.uid() = reviewee_id);

CREATE POLICY "Users can insert ratings for completed jobs"
ON ratings FOR INSERT TO authenticated
WITH CHECK (
    auth.uid() = reviewer_id AND
    EXISTS (
        SELECT 1 FROM jobs
        WHERE jobs.job_id = ratings.job_id
        AND jobs.status = 'completed'
        AND (
            (jobs.created_by = auth.uid() AND jobs.selected_applicant = ratings.reviewee_id) OR
            (jobs.selected_applicant = auth.uid() AND jobs.created_by = ratings.reviewee_id)
        )
    )
);

-- 18-20) General Access Policies
CREATE POLICY "Authenticated users can view all profiles"
ON users FOR SELECT TO authenticated USING (true);

CREATE POLICY "Users can insert own profile"
ON users FOR INSERT TO authenticated WITH CHECK (auth.uid() = uid);

CREATE POLICY "Users can update own profile"
ON users FOR UPDATE TO authenticated USING (auth.uid() = uid) WITH CHECK (auth.uid() = uid);

-- 21) Application Counts
CREATE OR REPLACE FUNCTION increment_application_count()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE jobs SET applications_count = applications_count + 1 WHERE job_id = NEW.job_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_application_created
AFTER INSERT ON applications
FOR EACH ROW EXECUTE FUNCTION increment_application_count();

CREATE OR REPLACE FUNCTION decrement_application_count()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE jobs SET applications_count = applications_count - 1 WHERE job_id = OLD.job_id;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_application_deleted
AFTER DELETE ON applications
FOR EACH ROW EXECUTE FUNCTION decrement_application_count();
