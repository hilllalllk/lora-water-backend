-- Sample data for development. Run it from the Supabase dashboard SQL Editor.
insert into public.devices (id, address, name, type) values
  ('node-1001', 4097, 'Depo-1 (prototip)', 'tank+valve'),   -- 0x1001
  ('node-1002', 4098, 'Terfi-1 (prototip)', 'tank+valve'),  -- 0x1002
  ('node-1003', 4099, 'Terfi merkezi (Modbus)', 'modbus')   -- 0x1003, firmware env node-modbus
on conflict (id) do nothing;

-- Example alarm thresholds (mm, centibar, seconds). Null disables a check.
update public.devices set
  level_low_mm = 300, level_high_mm = 1800,
  pressure_low_cbar = 50, pressure_high_cbar = 400,
  offline_after_s = 600
where id in ('node-1001', 'node-1002', 'node-1003');
