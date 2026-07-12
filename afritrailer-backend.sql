-- ============================================================================
-- AFRITRAILER — FULL CONSOLIDATED DATABASE BACKUP
-- Compiled from 26 sequential schema/patch iterations into one final state.
-- Safe to run top-to-bottom on a BRAND NEW Supabase project's SQL Editor.
-- ============================================================================
-- This file represents the FINAL resulting state of everything you built,
-- not a literal replay of every ALTER/DROP/UPDATE step. Where later patches
-- superseded earlier ones (e.g. referral commission logic, timezone fixes),
-- only the final version is included below.
--
-- A "KNOWN BEHAVIOR / THINGS TO REVIEW" section is at the very bottom —
-- read it before going to production. Nothing there was silently changed;
-- it's flagged, not fixed, so you can decide.
-- ============================================================================


-- ============================================================================
-- 0. EXTENSIONS
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
-- pg_cron powers the two scheduled jobs at the bottom of this file.
-- If this errors with a permissions issue, enable "pg_cron" first via
-- Supabase Dashboard → Database → Extensions, then re-run just this line.
CREATE EXTENSION IF NOT EXISTS "pg_cron";


-- ============================================================================
-- 1. TABLES
-- ============================================================================

-- Profiles (extends auth.users)
CREATE TABLE profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  phone TEXT UNIQUE NOT NULL,
  tier TEXT DEFAULT 'free' CHECK (tier IN ('free', 'A1', 'A2', 'A3', 'A4')),
  daily_limit INTEGER DEFAULT 0,
  tasks_completed_today INTEGER DEFAULT 0,
  last_reset_date DATE DEFAULT (now() AT TIME ZONE 'Africa/Kampala')::date,
  balance INTEGER DEFAULT 0,
  total_earned INTEGER DEFAULT 0,
  referral_code TEXT UNIQUE,
  referred_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  internship_active BOOLEAN DEFAULT false,
  internship_start_date TIMESTAMP WITH TIME ZONE,
  internship_used BOOLEAN DEFAULT false,
  wallet_names TEXT
);

-- Videos
CREATE TABLE videos (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  title TEXT NOT NULL,
  description TEXT,
  video_url TEXT NOT NULL,
  thumbnail_url TEXT,
  duration INTEGER NOT NULL,
  reward_amount INTEGER DEFAULT 300,
  required_watch_time INTEGER DEFAULT 10,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- User video watches
CREATE TABLE user_videos (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  video_id UUID REFERENCES videos(id) ON DELETE CASCADE,
  watched_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  watch_duration INTEGER NOT NULL,
  reward_earned INTEGER NOT NULL,
  claimed BOOLEAN DEFAULT true
);

-- Payment / upgrade / withdrawal requests
CREATE TABLE payment_requests (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  type TEXT CHECK (type IN ('tier_upgrade', 'investment', 'recharge', 'withdrawal')),
  amount INTEGER NOT NULL,
  tier TEXT,
  phone TEXT NOT NULL,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  admin_notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  completed_at TIMESTAMP WITH TIME ZONE
);

-- Referrals
CREATE TABLE referrals (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  referrer_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  referred_user_id UUID REFERENCES profiles(id) ON DELETE CASCADE UNIQUE,
  commission_earned INTEGER DEFAULT 0,
  first_upgrade_commission_paid BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Popups (in-app announcements)
CREATE TABLE popups (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  title TEXT,
  message TEXT,
  image_url TEXT,
  target TEXT DEFAULT 'all',
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- System settings (global / conditional system open-close control)
CREATE TABLE system_settings (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT,
  system_open BOOLEAN DEFAULT true,
  closure_message TEXT DEFAULT 'The system is currently closed. Please check back later.',
  target TEXT DEFAULT 'all', -- 'all', 'conditional', 'phone'
  target_phones TEXT[],
  exclude_phones TEXT[],
  target_tier TEXT,
  target_min_balance INTEGER,
  target_max_balance INTEGER,
  target_created_after TIMESTAMPTZ,
  target_created_before TIMESTAMPTZ,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Investment firms (progress display data)
CREATE TABLE investment_firms (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  firm_name TEXT UNIQUE,
  progress_percentage INTEGER DEFAULT 0 CHECK (progress_percentage >= 0 AND progress_percentage <= 100),
  days_until_full INTEGER DEFAULT 0,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);


-- ============================================================================
-- 2. INDEXES
-- ============================================================================

-- One video per calendar day per user, measured in Kampala local time
CREATE UNIQUE INDEX user_videos_unique_watch_day
ON public.user_videos (
  user_id,
  video_id,
  ((watched_at AT TIME ZONE 'Africa/Kampala')::date)
);

CREATE INDEX idx_profiles_referral_code ON profiles(referral_code);
CREATE INDEX idx_profiles_referred_by ON profiles(referred_by);
CREATE INDEX idx_user_videos_user_id ON user_videos(user_id);
CREATE INDEX idx_user_videos_watched_at ON user_videos(watched_at);
CREATE INDEX idx_payment_requests_user_id ON payment_requests(user_id);
CREATE INDEX idx_payment_requests_status ON payment_requests(status);
CREATE INDEX idx_referrals_referrer_id ON referrals(referrer_id);


-- ============================================================================
-- 3. FUNCTIONS
-- ============================================================================

-- 3.1 Tier configuration lookup
CREATE OR REPLACE FUNCTION get_tier_config(user_tier TEXT)
RETURNS TABLE (
  tier_name TEXT,
  daily_limit INTEGER,
  reward_per_video INTEGER,
  cost INTEGER
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    user_tier as tier_name,
    CASE user_tier
      WHEN 'free' THEN 0
      WHEN 'A1' THEN 5
      WHEN 'A2' THEN 10
      WHEN 'A3' THEN 14
      WHEN 'A4' THEN 20
      ELSE 0
    END as daily_limit,
    CASE user_tier
      WHEN 'free' THEN 0
      WHEN 'A1' THEN 250
      WHEN 'A2' THEN 450
      WHEN 'A3' THEN 625
      WHEN 'A4' THEN 1437
      ELSE 0
    END as reward_per_video,
    CASE user_tier
      WHEN 'free' THEN 0
      WHEN 'A1' THEN 30000
      WHEN 'A2' THEN 90000
      WHEN 'A3' THEN 210000
      WHEN 'A4' THEN 690000
      ELSE 0
    END as cost;
END;
$$ LANGUAGE plpgsql;

-- 3.2 Balance update on video watch
CREATE OR REPLACE FUNCTION update_balance_on_watch()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE profiles
  SET
    balance = balance + NEW.reward_earned,
    total_earned = total_earned + NEW.reward_earned,
    tasks_completed_today = tasks_completed_today + 1
  WHERE id = NEW.user_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3.3 Daily limit + Sunday closure enforcement
CREATE OR REPLACE FUNCTION check_daily_limit()
RETURNS TRIGGER AS $$
DECLARE
  user_tier TEXT;
  user_limit INTEGER;
  user_completed INTEGER;
  user_last_reset DATE;
  is_sunday BOOLEAN;
BEGIN
  is_sunday := EXTRACT(DOW FROM CURRENT_DATE) = 0;

  IF is_sunday THEN
    RAISE EXCEPTION 'System is closed on Sundays. Please come back tomorrow!';
  END IF;

  SELECT tier, daily_limit, tasks_completed_today, last_reset_date
  INTO user_tier, user_limit, user_completed, user_last_reset
  FROM profiles
  WHERE id = NEW.user_id;

  IF user_last_reset < CURRENT_DATE THEN
    UPDATE profiles
    SET
      tasks_completed_today = 0,
      last_reset_date = CURRENT_DATE
    WHERE id = NEW.user_id;

    user_completed := 0;
  END IF;

  IF user_completed >= user_limit THEN
    RAISE EXCEPTION 'Daily limit reached! You have watched %/% videos for % tier today. Upgrade your tier to watch more videos.',
      user_completed, user_limit, user_tier;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3.4 Update daily_limit automatically when tier changes
CREATE OR REPLACE FUNCTION update_daily_limit_on_tier_change()
RETURNS TRIGGER AS $$
DECLARE
  tier_config RECORD;
BEGIN
  IF NEW.tier IS DISTINCT FROM OLD.tier THEN
    SELECT * INTO tier_config FROM get_tier_config(NEW.tier);
    NEW.daily_limit := tier_config.daily_limit;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3.5 Referral code generation
CREATE OR REPLACE FUNCTION generate_referral_code()
RETURNS TEXT AS $$
DECLARE
  new_code TEXT;
  code_exists BOOLEAN;
BEGIN
  LOOP
    new_code := 'AFRITRAILER-' || UPPER(SUBSTRING(MD5(RANDOM()::TEXT || CLOCK_TIMESTAMP()::TEXT) FROM 1 FOR 6));
    SELECT EXISTS(SELECT 1 FROM profiles WHERE referral_code = new_code) INTO code_exists;
    EXIT WHEN NOT code_exists;
  END LOOP;

  RETURN new_code;
END;
$$ LANGUAGE plpgsql;

-- 3.6 New user defaults (referral code, daily limit, internship flags)
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.referral_code IS NULL THEN
    NEW.referral_code := generate_referral_code();
  END IF;

  IF NEW.daily_limit = 0 THEN
    SELECT daily_limit INTO NEW.daily_limit
    FROM get_tier_config(NEW.tier);
  END IF;

  NEW.internship_active := false;
  NEW.internship_used := false;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3.7 Internship activation
CREATE OR REPLACE FUNCTION activate_internship(user_id UUID)
RETURNS TEXT AS $$
DECLARE
  user_tier TEXT;
  already_used BOOLEAN;
  already_active BOOLEAN;
BEGIN
  SELECT tier, internship_used, internship_active
  INTO user_tier, already_used, already_active
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

-- 3.8 Internship expiry (run daily via cron)
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
    AND internship_start_date < NOW() - INTERVAL '4 days';
END;
$$ LANGUAGE plpgsql;

-- 3.9 Mark internship used when user upgrades off free tier
CREATE OR REPLACE FUNCTION mark_internship_used_on_upgrade()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.tier IN ('A1', 'A2', 'A3', 'A4') AND OLD.tier = 'free' THEN
    NEW.internship_used := true;
    NEW.internship_active := false;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3.10 Referral commission: 2% on every video watch
CREATE OR REPLACE FUNCTION process_video_referral_commission()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_referrer_id UUID;
    commission INTEGER;
BEGIN
    SELECT referred_by INTO v_referrer_id
    FROM profiles
    WHERE id = NEW.user_id;

    IF v_referrer_id IS NOT NULL THEN
        commission := FLOOR(NEW.reward_earned * 0.02);

        IF commission > 0 THEN
            UPDATE profiles
            SET balance = balance + commission
            WHERE id = v_referrer_id;

            UPDATE referrals
            SET commission_earned = commission_earned + commission
            WHERE referrer_id = v_referrer_id
            AND referred_user_id = NEW.user_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3.11 Referral commission: one-time 10% on first approved tier upgrade
CREATE OR REPLACE FUNCTION process_upgrade_referral_commission()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_referrer_id UUID;
    commission INTEGER;
    already_paid BOOLEAN;
BEGIN
    IF NEW.type != 'tier_upgrade' OR NEW.status != 'approved' THEN
        RETURN NEW;
    END IF;

    SELECT referred_by INTO v_referrer_id
    FROM profiles
    WHERE id = NEW.user_id;

    IF v_referrer_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT first_upgrade_commission_paid INTO already_paid
    FROM referrals
    WHERE referrer_id = v_referrer_id
    AND referred_user_id = NEW.user_id;

    IF already_paid IS TRUE THEN
        RETURN NEW;
    END IF;

    commission := FLOOR(NEW.amount * 0.10);

    UPDATE profiles
    SET balance = balance + commission
    WHERE id = v_referrer_id;

    UPDATE referrals
    SET
        commission_earned = commission_earned + commission,
        first_upgrade_commission_paid = true
    WHERE referrer_id = v_referrer_id
    AND referred_user_id = NEW.user_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3.12 Create the referrals row at signup time (required so 3.10/3.11 UPDATEs have a row to hit)
CREATE OR REPLACE FUNCTION create_referral_record()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.referred_by IS NOT NULL THEN
        INSERT INTO referrals (referrer_id, referred_user_id, commission_earned)
        VALUES (NEW.referred_by, NEW.id, 0)
        ON CONFLICT DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3.13 Daily task counter reset (run daily via cron, catches anyone missed by the lazy per-row reset in check_daily_limit)
CREATE OR REPLACE FUNCTION reset_daily_tasks()
RETURNS void AS $$
BEGIN
  UPDATE profiles
  SET
    tasks_completed_today = 0,
    last_reset_date = CURRENT_DATE
  WHERE last_reset_date < CURRENT_DATE;
END;
$$ LANGUAGE plpgsql;

-- 3.14 Safe referral-code lookup (returns only the matching profile id)
CREATE OR REPLACE FUNCTION get_referrer_id(code TEXT)
RETURNS UUID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_id UUID;
BEGIN
    SELECT id INTO v_id FROM profiles WHERE referral_code = code LIMIT 1;
    RETURN v_id;
END;
$$;


-- ============================================================================
-- 4. TRIGGERS
-- ============================================================================

CREATE TRIGGER set_user_defaults
  BEFORE INSERT ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION handle_new_user();

CREATE TRIGGER create_referral_on_signup
  AFTER INSERT ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION create_referral_record();

CREATE TRIGGER auto_update_daily_limit
  BEFORE UPDATE ON profiles
  FOR EACH ROW
  WHEN (OLD.tier IS DISTINCT FROM NEW.tier)
  EXECUTE FUNCTION update_daily_limit_on_tier_change();

CREATE TRIGGER mark_internship_on_tier_change
  BEFORE UPDATE ON profiles
  FOR EACH ROW
  WHEN (OLD.tier IS DISTINCT FROM NEW.tier)
  EXECUTE FUNCTION mark_internship_used_on_upgrade();

CREATE TRIGGER enforce_daily_limit
  BEFORE INSERT ON user_videos
  FOR EACH ROW
  EXECUTE FUNCTION check_daily_limit();

CREATE TRIGGER auto_update_balance
  AFTER INSERT ON user_videos
  FOR EACH ROW
  EXECUTE FUNCTION update_balance_on_watch();

CREATE TRIGGER process_video_referral_commission
  AFTER INSERT ON user_videos
  FOR EACH ROW
  EXECUTE FUNCTION process_video_referral_commission();

CREATE TRIGGER process_upgrade_referral_commission
  AFTER INSERT ON payment_requests
  FOR EACH ROW
  EXECUTE FUNCTION process_upgrade_referral_commission();


-- ============================================================================
-- 5. ROW LEVEL SECURITY
-- ============================================================================

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE videos ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_videos ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE popups ENABLE ROW LEVEL SECURITY;
ALTER TABLE system_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE investment_firms ENABLE ROW LEVEL SECURITY;

-- profiles
CREATE POLICY "Users can view own profile"
  ON profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Users can update own profile"
  ON profiles FOR UPDATE
  USING (auth.uid() = id);

CREATE POLICY "Users can insert own profile"
  ON profiles FOR INSERT
  WITH CHECK (auth.uid() = id);

CREATE POLICY "Anyone can look up referral codes"
  ON profiles FOR SELECT
  USING (true);

-- Column-level lockdown for anonymous requests (see notes at bottom re: authenticated role)
REVOKE SELECT ON profiles FROM anon;
GRANT SELECT (id, referral_code) ON profiles TO anon;

-- videos
CREATE POLICY "Anyone can view active videos"
  ON videos FOR SELECT
  USING (active = true);

-- user_videos
CREATE POLICY "Users can insert own watch"
  ON user_videos FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can view own watches"
  ON user_videos FOR SELECT
  USING (auth.uid() = user_id);

-- payment_requests
CREATE POLICY "Users can insert own requests"
  ON payment_requests FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can view own requests"
  ON payment_requests FOR SELECT
  USING (auth.uid() = user_id);

-- referrals (original owner-scoped policies + later fully-open policies; see notes at bottom)
CREATE POLICY "Users can view own referrals"
  ON referrals FOR SELECT
  USING (auth.uid() = referrer_id);

CREATE POLICY "Users can insert referrals"
  ON referrals FOR INSERT
  WITH CHECK (auth.uid() = referrer_id);

CREATE POLICY "Allow referral inserts"
  ON referrals FOR INSERT
  WITH CHECK (true);

CREATE POLICY "Allow referral reads"
  ON referrals FOR SELECT
  USING (true);

CREATE POLICY "Allow referral updates"
  ON referrals FOR UPDATE
  USING (true);

-- popups
CREATE POLICY "Users can read active popups"
  ON popups FOR SELECT
  USING (true);

-- system_settings
CREATE POLICY "Anyone can read system settings"
  ON system_settings FOR SELECT
  USING (true);

-- investment_firms
CREATE POLICY "Anyone can read investment firms"
  ON investment_firms FOR SELECT
  USING (true);


-- ============================================================================
-- 6. UTILITY VIEW
-- ============================================================================

CREATE OR REPLACE VIEW user_status AS
SELECT
  p.id,
  p.phone,
  p.tier,
  p.daily_limit,
  p.tasks_completed_today,
  (p.daily_limit - p.tasks_completed_today) as remaining_videos,
  p.balance,
  p.total_earned,
  p.referral_code,
  p.last_reset_date,
  CASE
    WHEN p.last_reset_date < CURRENT_DATE THEN true
    ELSE false
  END as needs_reset,
  CASE
    WHEN p.tasks_completed_today >= p.daily_limit THEN true
    ELSE false
  END as limit_reached,
  CASE
    WHEN EXTRACT(DOW FROM CURRENT_DATE) = 0 THEN true
    ELSE false
  END as is_sunday,
  tc.reward_per_video,
  tc.cost as tier_cost
FROM profiles p
CROSS JOIN LATERAL get_tier_config(p.tier) tc;


-- ============================================================================
-- 7. SEED DATA
-- ============================================================================

-- 7.1 Videos — final state: 14 African titles (Bunny CDN) + 14 African-American titles
INSERT INTO videos (title, description, video_url, thumbnail_url, duration, reward_amount, required_watch_time, active) VALUES
('Atlantics', 'African Film • Drama', 'https://afritrailer.b-cdn.net/ATLANTICS.mp4', 'https://res.cloudinary.com/deutyanql/video/upload/ATLANTICS_roxrjp.jpg', 120, 300, 10, true),
('Beasts of No Nation', 'African Film • War Drama', 'https://afritrailer.b-cdn.net/Beast%20of%20No%20nation.mp4', 'https://res.cloudinary.com/deutyanql/video/upload/Beasts_of_No_Nation_wtt99w.jpg', 120, 300, 10, true),
('Mad Buddies', 'African Film • Comedy', 'https://afritrailer.b-cdn.net/Mad%20buddies.mp4', 'https://res.cloudinary.com/deutyanql/video/upload/Mad_Buddies_zb8mtw.jpg', 120, 300, 10, true),
('Confusion Na Wa', 'African Film • Drama', 'https://afritrailer.b-cdn.net/CONFUSION%20NA_WA.mp4', 'https://res.cloudinary.com/deutyanql/video/upload/CONFUSION_NA_WA_tzxt94.jpg', 120, 300, 10, true),
('Necktie Youth', 'African Film • Drama', 'https://afritrailer.b-cdn.net/NeckTie%20Youth.mp4', 'https://res.cloudinary.com/deutyanql/video/upload/NeckTie_Youth_njm4i5.jpg', 120, 300, 10, true),
('Dhalinyaro', 'African Film • Drama', 'https://afritrailer.b-cdn.net/Dhalinyaro.mp4', 'https://res.cloudinary.com/deutyanql/video/upload/Dhalinyaro_gibd7q.jpg', 120, 300, 10, true),
('The Burial of Kojo', 'African Film • Drama', 'https://afritrailer.b-cdn.net/The%20burial%20of%20Kojo.mp4', 'https://res.cloudinary.com/deutyanql/video/upload/The_burial_of_Kojo_dnwngs.jpg', 120, 300, 10, true),
('Mami Wata', 'African Film • Fantasy', 'https://afritrailer.b-cdn.net/MAMI%20WATA.mp4', 'https://res.cloudinary.com/deutyanql/video/upload/MAMI_WATA_ebdgwa.jpg', 120, 300, 10, true),
('Saloum', 'African Film • Thriller', 'https://afritrailer.b-cdn.net/Saloum.mp4', 'https://res.cloudinary.com/deutyanql/video/upload/Saloum_ps6nx1.jpg', 120, 300, 10, true),
('The Woman King', 'African Film • Historical Drama', 'https://afritrailer.b-cdn.net/The%20woman%20King.mp4', 'https://res.cloudinary.com/deutyanql/video/upload/The_woman_King_ikwn88.jpg', 120, 300, 10, true),
('12 Years a Slave', 'African Film • Historical Drama', 'https://afritrailer.b-cdn.net/12%20years%20a%20slave.mp4', 'https://res.cloudinary.com/deutyanql/video/upload/12_years_a_slave_f65otb.jpg', 120, 300, 10, true),
('Hidden Figures', 'African Film • Historical Drama', 'https://afritrailer.b-cdn.net/Hidden%20Figures.mp4', 'https://res.cloudinary.com/deutyanql/video/upload/Hidden_Figures_gamunc.jpg', 120, 300, 10, true),
('Queen of Katwe', 'African Film • Drama', 'https://afritrailer.b-cdn.net/Queen%20of%20Katwe.mp4', 'https://res.cloudinary.com/deutyanql/video/upload/Queen_of_Katwe_k9u3h9.jpg', 120, 300, 10, true),
('Timbuktu', 'African Film • Drama', 'https://afritrailer.b-cdn.net/Timbuktu__2014__-_Trailer_English_Subs_1080p_jwzrrt.mp4', 'https://res.cloudinary.com/deutyanql/video/upload/Timbuktu__2014__-_Trailer_English_Subs_1080p_jwzrrt.jpg', 120, 300, 10, true),
('Black Panther', 'African American Film • Action', 'https://afritrailer.b-cdn.net/Black%20Panther.mp4', '', 0, 250, 10, true),
('Coming 2 America', 'African American Film • Comedy', 'https://afritrailer.b-cdn.net/Coming%202%20America.mp4', '', 0, 250, 10, true),
('Creed 3', 'African American Film • Sport', 'https://afritrailer.b-cdn.net/Creed%203.mp4', '', 0, 250, 10, true),
('Fences', 'African American Film • Drama', 'https://afritrailer.b-cdn.net/Fences.mp4', '', 0, 250, 10, true),
('Get Out', 'African American Film • Horror', 'https://afritrailer.b-cdn.net/Get%20Out.mp4', '', 0, 250, 10, true),
('Girls Trip', 'African American Film • Comedy', 'https://afritrailer.b-cdn.net/Girls%20Trip.mp4', '', 0, 250, 10, true),
('LIFT', 'African American Film • Action', 'https://afritrailer.b-cdn.net/LIFT.mp4', '', 0, 250, 10, true),
('Nope', 'African American Film • Horror', 'https://afritrailer.b-cdn.net/Nope.mp4', '', 0, 250, 10, true),
('Pursuit of Happyness', 'African American Film • Drama', 'https://afritrailer.b-cdn.net/Pursuit%20of%20Happyness.mp4', '', 0, 250, 10, true),
('Ray', 'African American Film • Biography', 'https://afritrailer.b-cdn.net/Ray.mp4', '', 0, 250, 10, true),
('Selma', 'African American Film • Historical Drama', 'https://afritrailer.b-cdn.net/Selma.mp4', '', 0, 250, 10, true),
('Sinners', 'African American Film • Thriller', 'https://afritrailer.b-cdn.net/Sinners.mp4', '', 0, 250, 10, true),
('Training Day', 'African American Film • Crime', 'https://afritrailer.b-cdn.net/Training%20Day.mp4', '', 0, 250, 10, true),
('US', 'African American Film • Horror', 'https://afritrailer.b-cdn.net/US.mp4', '', 0, 250, 10, true);

-- 7.2 System settings — 2 rows as configured in your live project
INSERT INTO system_settings (name, system_open, closure_message, target)
VALUES ('Global Closure', true, 'The system is currently closed. Please check back later.', 'all');

INSERT INTO system_settings (name, system_open, closure_message, target, target_phones, target_created_after, target_created_before)
VALUES ('Targeted Closure', false, 'Your account has been temporarily restricted. Please contact support.', 'conditional', ARRAY['+256759135858'], NULL, NULL);
-- NOTE: the phone number above matches a real account you targeted for closure
-- in your live project. Review whether you want this carried into a fresh
-- environment before running this file. See notes at bottom.

-- 7.3 Investment firms — 13 rows
INSERT INTO investment_firms (firm_name, progress_percentage, days_until_full) VALUES
('Old Mutual', 65, 5),
('Capital Alliance', 42, 18),
('Stanbic Investments', 78, 10),
('African Alliance', 30, 42),
('Centenary Capital', 55, 9),
('DFCU Investments', 88, 4),
('Vanguard Group', 25, 11),
('BlackRock', 60, 9),
('Fidelity Investments', 45, 20),
('Goldman Sachs', 70, 14),
('Morgan Stanley', 35, 75),
('J.P. Morgan Asset Management', 50, 98),
('World Liberty Financial', 20, 230);


-- ============================================================================
-- 8. SCHEDULED JOBS (pg_cron)
-- ============================================================================

SELECT cron.schedule(
  'reset-daily-tasks',
  '0 0 * * *',
  $$SELECT reset_daily_tasks()$$
);

SELECT cron.schedule(
  'expire-internships',
  '0 0 * * *',
  $$SELECT expire_internships()$$
);


-- ============================================================================
-- ✅ SETUP COMPLETE
-- ============================================================================
-- Tables: profiles, videos, user_videos, payment_requests, referrals,
--         popups, system_settings, investment_firms
-- 28 videos, 2 system_settings rows, 13 investment_firms rows seeded.
-- ============================================================================


-- ============================================================================
-- KNOWN BEHAVIOR / THINGS TO REVIEW (flagged during compilation, not changed)
-- ============================================================================
--
-- 1. PROFILES — overlapping read policies.
--    "Users can view own profile" (own row only) and "Anyone can look up
--    referral codes" (USING (true), all rows) are both permissive SELECT
--    policies and are OR'd together by Postgres RLS. The REVOKE/GRANT
--    below only restricts the `anon` role to (id, referral_code) columns.
--    The `authenticated` role was never revoked and keeps Supabase's
--    default full-column table grant — meaning any LOGGED-IN user can
--    currently read every column of every profile (phone, balance, tier,
--    etc.), not just their own. If that's not intended, either:
--      a) also run: REVOKE SELECT ON profiles FROM authenticated;
--                    GRANT SELECT (id, referral_code) ON profiles TO authenticated;
--      b) or drop "Anyone can look up referral codes" entirely and have
--         the frontend call get_referrer_id(code) instead, which already
--         exists for exactly this purpose and only returns a UUID.
--
-- 2. REFERRALS — fully open policies stacked on top of owner-scoped ones.
--    "Allow referral inserts/reads/updates" (USING/WITH CHECK (true)) make
--    the referrals table fully readable and writable by anyone, on top of
--    the original owner-scoped policies. Since process_video_referral_commission
--    and process_upgrade_referral_commission are SECURITY DEFINER, they no
--    longer need these open policies to function — they run as the function
--    owner and bypass RLS regardless. You may be able to safely drop the
--    three "Allow referral *" policies and rely on the owner-scoped ones only.
--
-- 3. PAYMENT_REQUESTS — upgrade commission trigger only fires on INSERT.
--    process_upgrade_referral_commission is AFTER INSERT only. If your app
--    inserts a payment_request as 'pending' and later UPDATEs it to
--    'approved' (typical admin-approval flow), this trigger will NEVER
--    fire, since it only runs at insert time — and at insert time status
--    is usually still 'pending'. If that's your flow, you likely also want:
--      CREATE TRIGGER process_upgrade_referral_commission_on_approve
--        AFTER UPDATE ON payment_requests
--        FOR EACH ROW
--        WHEN (OLD.status IS DISTINCT FROM NEW.status)
--        EXECUTE FUNCTION process_upgrade_referral_commission();
--    Not added automatically — confirm your actual approval flow first.
--
-- 4. SYSTEM_SETTINGS — "Targeted Closure" row ships with a real phone
--    number closed out (+256759135858). Reset target_phones to NULL and
--    system_open to true if you don't want that carried into a new project.
--
-- 5. POPUPS / SYSTEM_SETTINGS / INVESTMENT_FIRMS have read-only policies
--    and no INSERT/UPDATE policies for regular users. Writes to these
--    tables need to go through the Supabase service_role key (e.g. from
--    an admin panel or server-side function), not the anon/authenticated
--    client keys.
--
-- 6. pg_cron jobs run in UTC by default regardless of the Africa/Kampala
--    logic used elsewhere — '0 0 * * *' means midnight UTC (3am Kampala
--    time), not midnight Kampala time. reset_daily_tasks() and
--    expire_internships() will still work correctly since they compare
--    against CURRENT_DATE/NOW(), but the exact moment they run is 3am
--    Kampala time, not midnight. Adjust the cron expression to
--    '0 21 * * *' (9pm UTC = midnight Kampala, UTC+3) if you want it to
--    fire exactly at Kampala midnight.
-- ============================================================================