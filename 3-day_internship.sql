CREATE OR REPLACE FUNCTION expire_internships()
RETURNS void AS $$
BEGIN
  UPDATE profiles
  SET
    internship_active = false,
    daily_limit = 0,
    tasks_completed_today = 0
  WHERE
    internship_active = true
    AND internship_start_date < NOW() - INTERVAL '3 days';
END;
$$ LANGUAGE plpgsql;
