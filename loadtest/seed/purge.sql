-- =============================================================================
-- Remove exactly the rows seed.sql created, identified by their markers:
--   orders "LT-..." | products SKU "LT-..." | customers "lt...@loadtest.example"
--   categories "lt-cat-..", "lt-sub-.." | brands "lt-brand-.." | expenses "LT ..."
-- Nothing else is touched. Sizes and colours are shared reference data and are left.
-- Run through loadtest/seed/seed.sh --purge.
-- =============================================================================
SET SESSION foreign_key_checks = 0;
DELETE oh FROM order_status_history oh JOIN orders o ON o.id = oh.order_id WHERE o.order_no LIKE 'LT-%';
DELETE pay FROM payments pay JOIN orders o ON o.id = pay.order_id WHERE o.order_no LIKE 'LT-%';
DELETE op FROM ordered_products op JOIN orders o ON o.id = op.order_id WHERE o.order_no LIKE 'LT-%';
DELETE FROM orders WHERE order_no LIKE 'LT-%';
DELETE vp FROM variant_prices vp JOIN products p ON p.id = vp.product_id WHERE p.sku LIKE 'LT-%';
DELETE v FROM product_variants v JOIN products p ON p.id = v.product_id WHERE p.sku LIKE 'LT-%';
DELETE i FROM product_images i JOIN products p ON p.id = i.product_id WHERE p.sku LIKE 'LT-%';
DELETE FROM products WHERE sku LIKE 'LT-%';
DELETE FROM customers WHERE email LIKE 'lt%@loadtest.example';
DELETE FROM categories WHERE slug LIKE 'lt-sub-%';
DELETE FROM categories WHERE slug LIKE 'lt-cat-%';
DELETE FROM brands WHERE slug LIKE 'lt-brand-%';
DELETE FROM expenses WHERE title LIKE 'LT %';
DELETE FROM expense_categories WHERE title LIKE 'LT %';
DROP TABLE IF EXISTS lt_numbers;
DROP TABLE IF EXISTS lt_k;
DROP TABLE IF EXISTS lt_size_map;
DROP TABLE IF EXISTS lt_color_map;
SET SESSION foreign_key_checks = 1;
