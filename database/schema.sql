/*
Opportunity Tracker
Database Schema
Purpose:
Stores bursaries, internships, graduate programmes,
learnerships and other opportunities collected through
the automation workflow.
Database:
PostgreSQL (hosted on Neon)
*/
CREATE TABLE opportunities (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    org TEXT,
    type TEXT NOT NULL
        CHECK (type IN (
            'Bursary',
            'Internship',
            'Graduate Program',
            'Learnership',
            'Other'
        )),
    deadline DATE,
    link TEXT,
    requirements TEXT,
    status TEXT NOT NULL DEFAULT 'Not started'
        CHECK (status IN (
            'Not started',
            'In progress',
            'Submitted',
            'Expired'
        )),
    added_on DATE NOT NULL DEFAULT CURRENT_DATE,
    dedup_key TEXT UNIQUE
);
-- Indexes to improve filtering and sorting
CREATE INDEX idx_opportunities_deadline
    ON opportunities(deadline);
CREATE INDEX idx_opportunities_status
    ON opportunities(status);

------------------------------------------------------------
-- Example SQL used by the n8n PostgreSQL node
------------------------------------------------------------

-- INSERT INTO opportunities
-- (
--     title,
--     org,
--     type,
--     deadline,
--     link,
--     requirements,
--     status,
--     added_on,
--     dedup_key
-- )
-- VALUES
-- (
--     $1,
--     $2,
--     $3,
--     NULLIF($4,'')::DATE,
--     $5,
--     $6,
--     $7,
--     CURRENT_DATE,
--     $8
-- )
-- ON CONFLICT (dedup_key) DO NOTHING
-- RETURNING *;
------------------------------------------------------------
-- Example update used by the daily synchronization workflow
------------------------------------------------------------
-- UPDATE opportunities
-- SET status = 'Expired'
-- WHERE dedup_key = $1; 