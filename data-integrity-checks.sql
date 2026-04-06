-- ============================================================
-- QA DATA INTEGRITY SCRIPTS — Banking Context
-- Author: Valentina Ramos | QA Analyst
-- Purpose: Portfolio sample — data validation queries
-- Note: Uses generic/anonymized schema. No real bank data.
-- ============================================================


-- ------------------------------------------------------------
-- 1. ORPHANED RECORDS
--    Detect transactions with no associated account
-- ------------------------------------------------------------
SELECT
    t.transaction_id,
    t.account_id,
    t.amount,
    t.transaction_date,
    t.status
FROM transactions t
LEFT JOIN accounts a ON t.account_id = a.account_id
WHERE a.account_id IS NULL
ORDER BY t.transaction_date DESC;

-- Expected: 0 rows. Any result = data integrity issue.


-- ------------------------------------------------------------
-- 2. DUPLICATE TRANSACTIONS
--    Same account + amount + date within 5-minute window
--    (potential duplicate submission or race condition)
-- ------------------------------------------------------------
SELECT
    account_id,
    amount,
    transaction_date,
    COUNT(*) AS duplicate_count
FROM transactions
GROUP BY
    account_id,
    amount,
    TRUNC(transaction_date, 'MI') -- Oracle: truncate to minute
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC;

-- Expected: 0 rows. Duplicates indicate missing idempotency check.


-- ------------------------------------------------------------
-- 3. BALANCE MISMATCH
--    Account balance doesn't match sum of transactions
--    (detects calculation errors or missing rollbacks)
-- ------------------------------------------------------------
SELECT
    a.account_id,
    a.current_balance,
    NVL(SUM(
        CASE
            WHEN t.type = 'CREDIT' THEN t.amount
            WHEN t.type = 'DEBIT'  THEN -t.amount
            ELSE 0
        END
    ), 0) AS calculated_balance,
    a.current_balance - NVL(SUM(
        CASE
            WHEN t.type = 'CREDIT' THEN t.amount
            WHEN t.type = 'DEBIT'  THEN -t.amount
            ELSE 0
        END
    ), 0) AS discrepancy
FROM accounts a
LEFT JOIN transactions t ON a.account_id = t.account_id
    AND t.status = 'COMPLETED'
GROUP BY a.account_id, a.current_balance
HAVING ABS(
    a.current_balance - NVL(SUM(
        CASE
            WHEN t.type = 'CREDIT' THEN t.amount
            WHEN t.type = 'DEBIT'  THEN -t.amount
            ELSE 0
        END
    ), 0)
) > 0.01 -- tolerance for floating point
ORDER BY ABS(discrepancy) DESC;

-- Expected: 0 rows. Any discrepancy > $0.01 = critical defect.


-- ------------------------------------------------------------
-- 4. AUDIT LOG GAPS
--    Transactions without corresponding audit log entry
--    (compliance risk — every transaction must be logged)
-- ------------------------------------------------------------
SELECT
    t.transaction_id,
    t.account_id,
    t.amount,
    t.status,
    t.transaction_date
FROM transactions t
LEFT JOIN audit_log al ON t.transaction_id = al.transaction_id
WHERE al.log_id IS NULL
  AND t.status IN ('COMPLETED', 'FAILED', 'REVERSED')
ORDER BY t.transaction_date DESC;

-- Expected: 0 rows. Missing audit entries = compliance failure.


-- ------------------------------------------------------------
-- 5. FAILED ROLLBACKS (Zombie transactions)
--    Transactions marked FAILED but balance was still modified
-- ------------------------------------------------------------
SELECT
    t.transaction_id,
    t.account_id,
    t.amount,
    t.type,
    t.status,
    a.current_balance,
    al.log_action,
    al.log_timestamp
FROM transactions t
JOIN accounts a ON t.account_id = a.account_id
JOIN audit_log al ON t.transaction_id = al.transaction_id
WHERE t.status = 'FAILED'
  AND al.log_action IN ('BALANCE_UPDATED', 'DEBIT_APPLIED', 'CREDIT_APPLIED')
ORDER BY al.log_timestamp DESC;

-- Expected: 0 rows. FAILED transactions must not modify balances.


-- ------------------------------------------------------------
-- 6. ROLE/PROFILE PERMISSIONS AUDIT
--    Users with elevated permissions not matching their role
--    (tests role-based access control integrity)
-- ------------------------------------------------------------
SELECT
    u.user_id,
    u.username,
    u.role,
    p.permission_code,
    p.permission_description,
    rp.allowed -- should match expected for the role
FROM users u
JOIN user_permissions up ON u.user_id = up.user_id
JOIN permissions p ON up.permission_id = p.permission_id
LEFT JOIN role_permissions rp ON u.role = rp.role
    AND p.permission_id = rp.permission_id
WHERE rp.allowed IS NULL  -- permission not defined for this role
   OR rp.allowed = 'N'    -- or explicitly denied for this role
ORDER BY u.role, p.permission_code;

-- Expected: 0 rows. Indicates privilege escalation or misconfiguration.


-- ------------------------------------------------------------
-- 7. SPRINT METRICS QUERY
--    Bug count by severity for reporting
-- ------------------------------------------------------------
SELECT
    severity,
    status,
    COUNT(*) AS total_bugs,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct_of_total
FROM bugs
WHERE sprint_id = :sprint_id  -- bind variable
GROUP BY severity, status
ORDER BY
    CASE severity
        WHEN 'CRITICAL' THEN 1
        WHEN 'HIGH'     THEN 2
        WHEN 'MEDIUM'   THEN 3
        WHEN 'LOW'      THEN 4
    END,
    status;
