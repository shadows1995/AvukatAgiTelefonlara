
-- Allow users to update their own jobs (e.g. assign applicants)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'jobs' 
        AND policyname = 'Users can update their own jobs'
    ) THEN
        CREATE POLICY "Users can update their own jobs"
        ON jobs
        FOR UPDATE
        TO authenticated
        USING (auth.uid() = created_by)
        WITH CHECK (auth.uid() = created_by);
    END IF;
END $$;
