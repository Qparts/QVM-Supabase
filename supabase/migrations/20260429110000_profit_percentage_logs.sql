-- Create table for profit percentage update logs
CREATE TABLE IF NOT EXISTS qvm_new_apps.profit_percentage_update_logs (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL,
  user_name TEXT,
  update_method TEXT NOT NULL CHECK (update_method IN ('inline', 'bulk')),
  percentage_values JSONB NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('Asia/Riyadh', NOW()),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('Asia/Riyadh', NOW())
);

-- Add indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_profit_percentage_logs_user_id ON qvm_new_apps.profit_percentage_update_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_profit_percentage_logs_created_at ON qvm_new_apps.profit_percentage_update_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_profit_percentage_logs_method ON qvm_new_apps.profit_percentage_update_logs(update_method);

-- Add trigger to update updated_at timestamp
CREATE OR REPLACE FUNCTION qvm_new_apps.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW() AT TIME ZONE 'Asia/Riyadh';
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_profit_percentage_logs_updated_at ON qvm_new_apps.profit_percentage_update_logs;
CREATE TRIGGER update_profit_percentage_logs_updated_at
  BEFORE UPDATE ON qvm_new_apps.profit_percentage_update_logs
  FOR EACH ROW
  EXECUTE FUNCTION qvm_new_apps.update_updated_at_column();

-- Create RPC function to insert log entries
CREATE OR REPLACE FUNCTION public.log_profit_percentage_update(
  p_user_id UUID,
  p_update_method TEXT,
  p_percentage_values JSONB,
  p_user_name TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_log_id BIGINT;
BEGIN
  INSERT INTO qvm_new_apps.profit_percentage_update_logs (
    user_id,
    user_name,
    update_method,
    percentage_values
  ) VALUES (
    p_user_id,
    p_user_name,
    p_update_method,
    p_percentage_values
  ) RETURNING id INTO v_log_id;

  RETURN jsonb_build_object(
    'status', 'success',
    'message', 'Log entry created',
    'log_id', v_log_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.log_profit_percentage_update(uuid, text, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_profit_percentage_update(uuid, text, jsonb, text) TO authenticated;

-- Grant permissions on the table
REVOKE ALL ON TABLE qvm_new_apps.profit_percentage_update_logs FROM PUBLIC;
GRANT SELECT, INSERT ON TABLE qvm_new_apps.profit_percentage_update_logs TO authenticated;
