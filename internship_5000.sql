CREATE OR REPLACE FUNCTION activate_internship(user_id UUID)
RETURNS TEXT AS $$
DECLARE
  user_tier TEXT;
  already_used BOOLEAN;
  already_active BOOLEAN;
  user_balance INTEGER;
BEGIN
  SELECT tier, internship_used, internship_active, balance
  INTO user_tier, already_used, already_active, user_balance
  FROM profiles
  WHERE id = user_id;

  IF user_tier IN ('A1', 'A2', 'A3', 'A4') THEN
    RETURN 'error: already on paid tier';
  END IF;

  IF already_used THEN
    RETURN 'error: internship already used';
  END IF;

  IF already_active THEN
    RETURN 'error: internship already active';
  END IF;

  IF user_balance < 5000 THEN
    RETURN 'error: insufficient balance';
  END IF;

  UPDATE profiles
  SET
    internship_active = true,
    internship_start_date = NOW(),
    internship_used = true,
    daily_limit = 5
  WHERE id = user_id;

  RETURN 'success';
END;
$$ LANGUAGE plpgsql;
