# SMS Notification Workflow Documentation

This document serves as a reference for the SMS notification system in the AvukatAğı mobile application.

## Overview
The application uses a secure, server-side approach to send SMS notifications. The mobile app **does not** connect directly to the NetGSM API. Instead, it triggers endpoints on the `https://www.avukatagi.net` server, which then handles the secure communication with NetGSM.

## Core endpoints (Production)
Base URL: `https://www.avukatagi.net`

### 1. New Job Broadcast (Yeni Görev Bildirimi)
**Endpoint:** `/api/notify-new-job`
**Method:** `POST`
**Triggered By:** `src/screens/jobs/CreateJobScreen.tsx` (after successful DB insert)
**Purpose:** Scans the database for lawyers matching the job's criteria (City, Courthouse) and sends a bulk SMS.

**Request Body:**
```json
{
  "city": "İstanbul",
  "courthouse": "İstanbul Adliyesi (Çağlayan)",
  "jobType": "Duruşma",
  "fee": 1000,           // Number
  "offeredFee": 1000,    // Number (Same as fee, for redundancy)
  "date": "2024-12-06T...", // ISO String
  "jobId": null,         // Optional
  "createdBy": "uid..."  // User ID
}
```

**Workflow:**
1.  User fills "Create Job" form.
2.  App inserts job into Supabase `jobs` table.
3.  **Immediately** after success, App calls `fetch('https://www.avukatagi.net/api/notify-new-job', ...)`
4.  Server queries `users` table for matching `preferred_courthouses`.
5.  Server formats message: *"Sayın Meslektaşımız, {courthouse} adliyesinde..."*
6.  Server sends batch SMS via NetGSM.

### 2. Single User Notification (Seçilen Avukata Bildirim)
**Endpoint:** `/api/send-sms`
**Helper Function:** `sendSmsViaServer` in `src/services/api.ts`
**Triggered By:** `src/screens/jobs/JobsScreen.tsx` (when an applicant is accepted)
**Purpose:** Notifies a specific user that they have been selected for a job.

**Request Body:**
```json
{
  "phone": "5xxxxxxxxx", // Clean number or with 90 prefix
  "message": "Sayın Av. X, ... görevine seçildiniz."
}
```

**Workflow:**
1.  Job Owner approves an applicant.
2.  App calls `sendSmsViaServer(phone, message)`.
3.  Endpoint authenticates the request (checks valid session if implemented, or relies on server-side key).
4.  Server sends single SMS via NetGSM.

### 3. Server Health Check
**Endpoint:** `/api/health`
**Helper Function:** `pingHealth` in `src/services/api.ts`
**Purpose:** Verifies connectivity to the backend server.
**Response:** `200 OK`

## Key implementation Rules

1.  **Always Use Production URL:**
    For SMS features, hardcode the server URL to `https://www.avukatagi.net`. Do not use `localhost` or local IP addresses because the NetGSM integration and robust broadcasting logic reside on the live server.
    
    ```typescript
    // In CreateJobScreen.tsx and api.ts (for SMS)
    const SERVER_URL = 'https://www.avukatagi.net';
    ```

2.  **No Client-Side Credentials:**
    Never include NetGSM username/password or `SUPABASE_SERVICE_ROLE_KEY` in the mobile app code.

3.  **Error Handling:**
    The broadcast call should be "fire and forget" or non-blocking for the UI. If it fails, log the error (`console.error`), but do not crash the app or prevent the user from seeing the "Job Created" success message.

4.  **Debugging:**
    Use `src/screens/debug/DebugScreen.tsx` (accessible via Settings -> "API Bağlantı Testi" for Admins) to verify connectivity if users report issues.

## Debugging Checklist
If SMS is not working:
1.  **Check Internet:** Can the device open `https://www.avukatagi.net/api/health` in a browser?
2.  **Check Payload:** Ensure `fee` is a Number and `courthouse` matches exactly what is in the DB.
3.  **Server Logs:** Check the Vercel/Server logs for `/api/notify-new-job` errors.
