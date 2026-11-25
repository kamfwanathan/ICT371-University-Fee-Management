-- ICT371 Q2: University Fee Payments  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

-- (a) Tables
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL,
  fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
  payment_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on    DATE NOT NULL DEFAULT CURRENT_DATE
);
CREATE TABLE payment_audit (
  audit_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  payment_id INT NOT NULL REFERENCES payments(payment_id),
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL,
  logged_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count   INT NOT NULL,
  total_amount    NUMERIC(12,2) NOT NULL
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
  ('S2023001', 'Mwansa Banda',  5000.00),
  ('S2023002', 'Chanda Phiri',  3000.00),
  ('S2023003', 'Temwani Zulu',  2000.00);   -- no payments

-- (b) Function
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC AS $$
DECLARE v_fee NUMERIC;
BEGIN
  SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student_id %', p_student_id;
  END IF;
  RETURN v_fee - COALESCE((SELECT SUM(amount) FROM payments WHERE student_id = p_student_id), 0);
END;
$$ LANGUAGE plpgsql STABLE;

-- (d) Trigger: the ONLY place the audit row is written
CREATE OR REPLACE FUNCTION trg_payment_audit() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payment_audit();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Invalid payment amount: %', p_amount;
  END IF;
  -- lock the student row so two simultaneous payments cannot overpay
  PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student_id %', p_student_id;
  END IF;
  v_balance := fn_fee_balance(p_student_id);
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
  END IF;
  INSERT INTO payments (student_id, amount, paid_on)
  VALUES (p_student_id, p_amount, COALESCE(p_paid_on, CURRENT_DATE));
END;
$$;

-- Seed payments through the procedure (7 payments; student 2 fully settled, student 3 none)
CALL pr_receive_payment(1, 1000, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 1000, CURRENT_DATE - 2);
CALL pr_receive_payment(1,  500, CURRENT_DATE - 1);
CALL pr_receive_payment(1,  500, CURRENT_DATE);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 1);

-- Rejection tests:
-- CALL pr_receive_payment(1, NULL, CURRENT_DATE);
-- CALL pr_receive_payment(1, 0, CURRENT_DATE);
-- CALL pr_receive_payment(1, 99999, CURRENT_DATE);
-- SELECT fn_fee_balance(3);   -- 2000.00 (full fee)

-- (e) View: students who still owe
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

SELECT * FROM v_fee_balances;

-- (f) Composite index: equality column first, range column second
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
-- Justification: filtering on student_id = ? AND paid_on BETWEEN ? AND ? is answered
-- by a single index range scan; reversing the order would not allow that.
ANALYZE payments;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Refresh procedure
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_collections (collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
  FROM payments WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END;
$$;

SELECT cron.schedule('refresh_collections_daily', '0 1 * * *',
  $cron$CALL pr_refresh_collections(CURRENT_DATE - 1)$cron$);

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);   -- rerun replaces the row
SELECT * FROM daily_collections;
SELECT * FROM payment_audit ORDER BY audit_id;
