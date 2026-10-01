-- =============================================================================
-- Realistic test data for a CRM store: catalogue, customers, orders and their lines.
-- Run through loadtest/seed/seed.sh, which sets these variables and checks that the
-- store holds no real data first:
--   @lt_products  @lt_customers  @lt_orders  @lt_months  @lt_seed
-- Everything created here is marked (SKUs, slugs, order numbers and e-mails start with
-- "LT" / "lt-") so purge.sql can remove exactly it. Values are derived from CRC32 hashes
-- of the row number, so a run is repeatable for the same @lt_seed and works on both
-- MariaDB and MySQL. Shapes follow the application's own demo seeder (statuses and
-- weights, payment methods, Bangladeshi districts), with realistic skew: popular products,
-- repeat customers, more recent orders than old ones.
-- =============================================================================
SET @s = CAST(@lt_seed AS CHAR);
SET @now = NOW();
SET @p0 = (SELECT IFNULL(MAX(id), 0) FROM products);
SET @c0 = (SELECT IFNULL(MAX(id), 0) FROM customers);
SET @o0 = (SELECT IFNULL(MAX(id), 0) FROM orders);
SET @cat0 = (SELECT IFNULL(MAX(id), 0) FROM categories);
SET @br0 = (SELECT IFNULL(MAX(id), 0) FROM brands);
SET @ec0 = (SELECT IFNULL(MAX(id), 0) FROM expense_categories);
SET SESSION foreign_key_checks = 0;
SET SESSION unique_checks = 0;

-- ── helper tables ────────────────────────────────────────────────────────────
DROP TABLE IF EXISTS lt_numbers;
DROP TABLE IF EXISTS lt_k;
CREATE TABLE lt_numbers (n INT UNSIGNED NOT NULL PRIMARY KEY) ENGINE=InnoDB;
CREATE TABLE lt_k (k TINYINT UNSIGNED NOT NULL PRIMARY KEY) ENGINE=InnoDB;
INSERT INTO lt_k VALUES (1), (2), (3), (4), (5), (6);
SET @maxn = GREATEST(@lt_products, @lt_customers, @lt_orders, 100);
INSERT INTO lt_numbers (n)
SELECT a.d + 10 * b.d + 100 * c.d + 1000 * d.d + 10000 * e.d + 100000 * f.d + 1
FROM (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a,
     (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b,
     (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) c,
     (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d,
     (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) e,
     (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) f
WHERE a.d + 10 * b.d + 100 * c.d + 1000 * d.d + 10000 * e.d + 100000 * f.d + 1 <= @maxn;

-- ── reference data ───────────────────────────────────────────────────────────
INSERT INTO categories (id, name, slug, status, sort_order, created_at, updated_at)
SELECT @cat0 + m.k, ELT(m.k, 'Men', 'Women', 'Kids', 'Accessories', 'Footwear', 'Home', 'Beauty', 'Sports'),
       CONCAT('lt-cat-', m.k), 'active', m.k, @now, @now
FROM (SELECT k FROM lt_k UNION ALL SELECT 7 UNION ALL SELECT 8) m;
-- sub-categories: three under each of the 8 main ones (ids after the mains)
INSERT INTO categories (id, name, slug, parent_id, status, sort_order, created_at, updated_at)
SELECT @cat0 + 8 + (m.k - 1) * 3 + s.k, ELT(s.k, 'Casual', 'Formal', 'Sports'),
       CONCAT('lt-sub-', m.k, '-', s.k), @cat0 + m.k, 'active', s.k, @now, @now
FROM (SELECT k FROM lt_k UNION ALL SELECT 7 UNION ALL SELECT 8) m, (SELECT k FROM lt_k WHERE k <= 3) s;

INSERT INTO brands (id, name, slug, created_at, updated_at)
SELECT @br0 + n.n, CONCAT('LT Brand ', LPAD(n.n, 2, '0')), CONCAT('lt-brand-', LPAD(n.n, 2, '0')), @now, @now
FROM lt_numbers n WHERE n.n <= 20;
INSERT IGNORE INTO sizes (label, created_at, updated_at)
SELECT ELT(k.k, 'S', 'M', 'L', 'XL', 'XXL', '38'), @now, @now FROM lt_k k;
INSERT IGNORE INTO sizes (label, created_at, updated_at)
SELECT ELT(k.k, '39', '40', '41', '42'), @now, @now FROM lt_k k WHERE k.k <= 4;
INSERT IGNORE INTO colors (label, hex_value, created_at, updated_at)
SELECT ELT(k.k, 'Black', 'White', 'Navy', 'Red', 'Olive', 'Grey'), ELT(k.k, '#111111', '#ffffff', '#1f2a44', '#c0392b', '#556b2f', '#808080'), @now, @now FROM lt_k k;
INSERT IGNORE INTO colors (label, hex_value, created_at, updated_at)
SELECT ELT(k.k, 'Beige', 'Maroon', 'Teal', 'Mustard'), ELT(k.k, '#d9c9a3', '#800000', '#008080', '#e1ad01'), @now, @now FROM lt_k k WHERE k.k <= 4;
INSERT INTO expense_categories (id, title, created_at)
SELECT @ec0 + k.k, CONCAT('LT ', ELT(k.k, 'Operations', 'Logistics', 'Marketing', 'Utilities', 'Staff', 'Miscellaneous')), @now FROM lt_k k;
-- positions 0..9 -> real ids, whatever the ids of these labels are in this store
DROP TABLE IF EXISTS lt_size_map;
DROP TABLE IF EXISTS lt_color_map;
CREATE TABLE lt_size_map (idx TINYINT UNSIGNED NOT NULL PRIMARY KEY, id BIGINT UNSIGNED NOT NULL) ENGINE=InnoDB;
CREATE TABLE lt_color_map (idx TINYINT UNSIGNED NOT NULL PRIMARY KEY, id BIGINT UNSIGNED NOT NULL) ENGINE=InnoDB;
INSERT INTO lt_size_map SELECT ROW_NUMBER() OVER (ORDER BY id) - 1, id FROM sizes WHERE label IN ('S', 'M', 'L', 'XL', 'XXL', '38', '39', '40', '41', '42');
INSERT INTO lt_color_map SELECT ROW_NUMBER() OVER (ORDER BY id) - 1, id FROM colors WHERE label IN ('Black', 'White', 'Navy', 'Red', 'Olive', 'Grey', 'Beige', 'Maroon', 'Teal', 'Mustard');

-- ── products ─────────────────────────────────────────────────────────────────
INSERT INTO products (id, title, sku, regular_price, selling_price, purchase_price, main_category_id, sub_category_id,
                      product_short_description, product_long_description, product_thumbnail_img, has_variants,
                      has_variant_wise_pricing, status, has_free_shipping, product_type, product_slug, brand_id, tags,
                      gender, style, available_stock, created_at, updated_at)
SELECT @p0 + n.n,
       t.title,
       CONCAT('LT-', LPAD(n.n, 6, '0')),
       ROUND(t.price * 1.2), t.price, ROUND(t.price * 0.55),
       @cat0 + t.main, @cat0 + 8 + (t.main - 1) * 3 + t.sub,
       CONCAT(t.title, ' - a comfortable everyday piece.'),
       CONCAT(t.title, '. ', REPEAT('Made from breathable fabric with careful stitching, designed to last through everyday wear and frequent washing. ', 4)),
       CONCAT('products/lt-', n.n, '.jpg'),
       t.var, IF(t.var = 1 AND t.h4 % 100 < 20, 1, 0),
       IF(t.h5 % 100 < 93, 'active', 'inactive'), IF(t.h5 % 100 < 10, 1, 0), NULL,
       CONCAT('lt-', LPAD(n.n, 6, '0')),
       @br0 + 1 + t.h6 % 20,
       CONCAT('["', ELT(1 + t.h7 % 6, 'summer', 'winter', 'cotton', 'new', 'sale', 'festive'), '","', ELT(1 + t.h8 % 6, 'casual', 'formal', 'sport', 'party', 'daily', 'premium'), '"]'),
       ELT(1 + t.h9 % 4, 'Men', 'Women', 'Unisex', 'Kids'), ELT(1 + t.h1 % 3, 'Casual', 'Formal', 'Sports'),
       t.h2 % 150,
       DATE_SUB(@now, INTERVAL FLOOR(t.u * 730) DAY), DATE_SUB(@now, INTERVAL FLOOR(t.u * 300) DAY)
FROM (
  SELECT n.n AS id,
         CONCAT(ELT(1 + CRC32(CONCAT(@s, 'a:', n.n)) % 12, 'Classic', 'Modern', 'Soft', 'Slim', 'Relaxed', 'Printed', 'Plain', 'Embroidered', 'Premium', 'Everyday', 'Light', 'Heritage'), ' ',
                ELT(1 + CRC32(CONCAT(@s, 'b:', n.n)) % 28, 'Ethnic Sandals', 'Kurti', 'Casual Slippers', 'Puff Sleeve Top', 'Denim Jacket', 'Cotton Panjabi', 'Silk Saree', 'Linen Shirt', 'Chino Pants', 'T-Shirt', 'Polo Tee', 'Sneakers', 'Leather Belt', 'Canvas Backpack', 'Sunglasses', 'Running Shorts', 'Floral Dress', 'Ribbed Sweater', 'Cargo Joggers', 'Hoodie', 'Embroidered Kurti', 'Linen Trousers', 'V-Neck Tee', 'Platform Heels', 'Crossbody Bag', 'Woven Bracelet', 'Striped Scarf', 'Knit Beanie')) AS title,
         250 + FLOOR(POW(CRC32(CONCAT(@s, 'c:', n.n)) / 4294967296, 1.6) * 4250) AS price,
         1 + CRC32(CONCAT(@s, 'd:', n.n)) % 8 AS main,
         1 + CRC32(CONCAT(@s, 'e:', n.n)) % 3 AS sub,
         IF(CRC32(CONCAT(@s, 'f:', n.n)) % 100 < 60, 1, 0) AS var,
         CRC32(CONCAT(@s, 'g:', n.n)) / 4294967296 AS u,
         CRC32(CONCAT(@s, 'h1:', n.n)) AS h1, CRC32(CONCAT(@s, 'h2:', n.n)) AS h2,
         CRC32(CONCAT(@s, 'h4:', n.n)) AS h4, CRC32(CONCAT(@s, 'h5:', n.n)) AS h5,
         CRC32(CONCAT(@s, 'h6:', n.n)) AS h6, CRC32(CONCAT(@s, 'h7:', n.n)) AS h7,
         CRC32(CONCAT(@s, 'h8:', n.n)) AS h8, CRC32(CONCAT(@s, 'h9:', n.n)) AS h9
  FROM lt_numbers n WHERE n.n <= @lt_products
) t
JOIN lt_numbers n ON n.n = t.id;

-- variants: 3 to 6 size/colour combinations for products that have them
INSERT INTO product_variants (product_id, sku, size_id, color_id, available_stock, created_at, updated_at)
SELECT p.id, CONCAT(p.sku, '-', k.k), sm.id, cm.id,
       CRC32(CONCAT(@s, 'vs:', p.id, ':', k.k)) % 60, p.created_at, p.created_at
FROM products p
JOIN lt_k k ON k.k <= 3 + CRC32(CONCAT(@s, 'vn:', p.id)) % 4
JOIN lt_size_map sm ON sm.idx = (p.id + k.k) % 10
JOIN lt_color_map cm ON cm.idx = (p.id * 3 + k.k) % 10
WHERE p.id > @p0 AND p.has_variants = 1;
INSERT INTO variant_prices (product_id, variant_id, regular_price, selling_price, created_at, updated_at)
SELECT p.id, v.id, ROUND(p.selling_price * 1.2 * (1 + (v.id % 5) / 20)), ROUND(p.selling_price * (1 + (v.id % 5) / 20)), p.created_at, p.created_at
FROM products p JOIN product_variants v ON v.product_id = p.id
WHERE p.id > @p0 AND p.has_variant_wise_pricing = 1;
INSERT INTO product_images (product_id, product_img, sort, created_at, updated_at)
SELECT p.id, CONCAT('products/lt-', p.id - @p0, '-', k.k, '.jpg'), k.k, p.created_at, p.created_at
FROM products p JOIN lt_k k ON k.k <= 1 + CRC32(CONCAT(@s, 'im:', p.id)) % 4
WHERE p.id > @p0;

-- ── customers: repeat buyers exist, so orders reference a skewed subset ──────
INSERT INTO customers (id, full_name, phone, email, gender, status, is_phone_verified, is_email_verified, created_at, updated_at)
SELECT @c0 + n.n,
       CONCAT(ELT(1 + CRC32(CONCAT(@s, 'fn:', n.n)) % 30, 'Rahim', 'Karim', 'Fatima', 'Ayesha', 'Tanvir', 'Nusrat', 'Sakib', 'Maliha', 'Imran', 'Tasnim', 'Zara', 'Farhan', 'Sumaiya', 'Arif', 'Nadia', 'Shahriar', 'Rohima', 'Jahangir', 'Ruma', 'Habib', 'Mehedi', 'Sadia', 'Rafi', 'Lamia', 'Nabil', 'Shirin', 'Tareq', 'Mim', 'Asif', 'Priya'), ' ',
              ELT(1 + CRC32(CONCAT(@s, 'ln:', n.n)) % 24, 'Uddin', 'Ahmed', 'Begum', 'Siddiqua', 'Hasan', 'Jahan', 'Al Hasan', 'Rahman', 'Hossain', 'Khan', 'Ali', 'Akter', 'Mahmud', 'Kabir', 'Alam', 'Islam', 'Chowdhury', 'Sarker', 'Mia', 'Miah', 'Talukder', 'Bhuiyan', 'Sheikh', 'Roy')),
       CONCAT('01', LPAD(300000000 + n.n * 13, 9, '0')),
       CONCAT('lt', n.n, '@loadtest.example'),
       ELT(1 + CRC32(CONCAT(@s, 'cg:', n.n)) % 3, 'male', 'female', 'other'), 'active',
       IF(CRC32(CONCAT(@s, 'pv:', n.n)) % 100 < 70, 1, 0), 0,
       DATE_SUB(@now, INTERVAL FLOOR(CRC32(CONCAT(@s, 'cd:', n.n)) / 4294967296 * 730) DAY), @now
FROM lt_numbers n WHERE n.n <= @lt_customers;

-- ── orders ───────────────────────────────────────────────────────────────────
INSERT INTO orders (id, order_no, customer_id, customer_full_name, customer_phone, customer_email, customer_shipping_address,
                    shipping_area, district, subtotal_amount, discount_amount, shipping_charge, grand_total_amount,
                    order_status, payment_status, order_visibility, source, invoice_status, created_at, updated_at)
SELECT @o0 + n.id, CONCAT('LT-', LPAD(n.id, 7, '0')), c.id, c.full_name, c.phone, c.email,
       CONCAT(ELT(1 + n.h1 % 12, 'Uttara', 'Banani', 'Gulshan', 'Dhanmondi', 'Mirpur', 'Mohammadpur', 'Motijheel', 'Farmgate', 'Tejgaon', 'Bashundhara', 'Waripara', 'Badda'), ', ',
              ELT(1 + n.h2 % 12, 'Dhaka', 'Chattogram', 'Sylhet', 'Rajshahi', 'Khulna', 'Barishal', 'Rangpur', 'Mymensingh', 'Comilla', 'Gazipur', 'Narayanganj', 'Bogra'), ' - House ', 1 + n.h3 % 99),
       ELT(1 + n.h1 % 12, 'Uttara', 'Banani', 'Gulshan', 'Dhanmondi', 'Mirpur', 'Mohammadpur', 'Motijheel', 'Farmgate', 'Tejgaon', 'Bashundhara', 'Waripara', 'Badda'),
       ELT(1 + n.h2 % 12, 'Dhaka', 'Chattogram', 'Sylhet', 'Rajshahi', 'Khulna', 'Barishal', 'Rangpur', 'Mymensingh', 'Comilla', 'Gazipur', 'Narayanganj', 'Bogra'),
       0, 0, 0, 0,
       n.status,
       CASE WHEN n.status IN ('Delivered', 'Confirmed', 'Ready To Ship', 'In-Courier') THEN 'Paid'
            WHEN n.status IN ('Cancelled', 'Fake', 'Returned') THEN 'Unpaid'
            WHEN n.h4 % 2 = 0 THEN 'Paid' ELSE 'Unpaid' END,
       'show', ELT(1 + n.h5 % 4, 'Facebook', 'Website', 'Instagram', 'Manual'), 'Not Invoiced',
       n.created, n.created
FROM (
  SELECT m.n AS id, m.h1, m.h2, m.h3, m.h4, m.h5,
         CASE WHEN m.r < 15 THEN 'Pending' WHEN m.r < 40 THEN 'Confirmed' WHEN m.r < 55 THEN 'Ready To Ship'
              WHEN m.r < 65 THEN 'In-Courier' WHEN m.r < 90 THEN 'Delivered' WHEN m.r < 95 THEN 'Cancelled'
              WHEN m.r < 98 THEN 'Fake' WHEN m.r < 99 THEN 'Hold' ELSE 'Returned' END AS status,
         m.cust,
         DATE_SUB(DATE_SUB(DATE_SUB(@now, INTERVAL FLOOR(POW(m.u, 1.3) * @lt_months * 30) DAY), INTERVAL (m.h3 % 14) HOUR), INTERVAL (m.h5 % 60) MINUTE) AS created
  FROM (
    SELECT n.n,
           CRC32(CONCAT(@s, 'o1:', n.n)) AS h1, CRC32(CONCAT(@s, 'o2:', n.n)) AS h2, CRC32(CONCAT(@s, 'o3:', n.n)) AS h3,
           CRC32(CONCAT(@s, 'o4:', n.n)) AS h4, CRC32(CONCAT(@s, 'o5:', n.n)) AS h5,
           CRC32(CONCAT(@s, 'o6:', n.n)) % 100 AS r,
           CRC32(CONCAT(@s, 'o7:', n.n)) / 4294967296 AS u,
           @c0 + 1 + FLOOR(@lt_customers * POW(CRC32(CONCAT(@s, 'o8:', n.n)) / 4294967296, 1.7)) AS cust
    FROM lt_numbers n WHERE n.n <= @lt_orders
  ) m
) n
JOIN customers c ON c.id = n.cust;

-- order lines: one to three, skewed towards popular (low id) products
INSERT INTO ordered_products (order_id, order_no, product_id, unit_price, qty, purchase_price, is_gift, created_at, updated_at)
SELECT o.id, o.order_no, p.id, p.selling_price, 1 + CRC32(CONCAT(@s, 'q:', o.id, ':', k.k)) % 3, ROUND(p.selling_price * 0.55), 0, o.created_at, o.created_at
FROM orders o
JOIN lt_k k ON k.k <= 1 + CRC32(CONCAT(@s, 'li:', o.id)) % 3
JOIN products p ON p.id = @p0 + 1 + FLOOR(@lt_products * POW(CRC32(CONCAT(@s, 'lp:', o.id, ':', k.k)) / 4294967296, 2))
WHERE o.id > @o0;

UPDATE orders o
JOIN (SELECT order_id, SUM(unit_price * qty) AS s FROM ordered_products WHERE order_id > @o0 GROUP BY order_id) t ON t.order_id = o.id
SET o.subtotal_amount = t.s,
    o.discount_amount = IF(CRC32(CONCAT(@s, 'ds:', o.id)) % 2 = 0, 0, ROUND(t.s * 0.05)),
    o.shipping_charge = IF(CRC32(CONCAT(@s, 'sh:', o.id)) % 2 = 0, 0, IF(o.district = 'Dhaka', 60, 120)),
    o.grand_total_amount = t.s - IF(CRC32(CONCAT(@s, 'ds:', o.id)) % 2 = 0, 0, ROUND(t.s * 0.05))
                           + IF(CRC32(CONCAT(@s, 'sh:', o.id)) % 2 = 0, 0, IF(o.district = 'Dhaka', 60, 120))
WHERE o.id > @o0;

INSERT INTO payments (order_id, order_no, payment_method, paid_amount, created_at, updated_at)
SELECT o.id, o.order_no,
       ELT(1 + CRC32(CONCAT(@s, 'pm:', o.id)) % 10, 'Cash on Delivery', 'Cash on Delivery', 'Cash on Delivery', 'sslcommerz', 'sslcommerz', 'bKash', 'bKash', 'Rocket', 'Upay', 'Nagad'),
       o.grand_total_amount, o.created_at, o.created_at
FROM orders o WHERE o.id > @o0 AND o.payment_status = 'Paid';

INSERT INTO order_status_history (order_id, from_status, to_status, created_at, updated_at)
SELECT o.id, NULL, 'Pending', o.created_at, o.created_at FROM orders o WHERE o.id > @o0;
INSERT INTO order_status_history (order_id, from_status, to_status, created_at, updated_at)
SELECT o.id, 'Pending', o.order_status, DATE_ADD(o.created_at, INTERVAL 1 + CRC32(CONCAT(@s, 'hh:', o.id)) % 48 HOUR), o.updated_at
FROM orders o WHERE o.id > @o0 AND o.order_status <> 'Pending';

-- expenses: a handful every month, for the dashboard
INSERT INTO expenses (title, expense_category_id, amount, description, created_at)
SELECT CONCAT('LT ', ELT(1 + CRC32(CONCAT(@s, 'et:', m.n, ':', k.k)) % 6, 'Office Rent', 'Courier Charge', 'Staff Salary', 'Packaging', 'Internet Bill', 'Marketing Ads')),
       @ec0 + 1 + CRC32(CONCAT(@s, 'ec:', m.n, ':', k.k)) % 6,
       2000 + CRC32(CONCAT(@s, 'ea:', m.n, ':', k.k)) % 33000,
       'Generated for load testing',
       DATE_SUB(@now, INTERVAL (m.n - 1) * 30 + CRC32(CONCAT(@s, 'ed:', m.n, ':', k.k)) % 27 DAY)
FROM lt_numbers m JOIN lt_k k ON k.k <= 5 WHERE m.n <= @lt_months;

-- ── finish ───────────────────────────────────────────────────────────────────
DROP TABLE lt_numbers;
DROP TABLE lt_k;
DROP TABLE lt_size_map;
DROP TABLE lt_color_map;
SET SESSION unique_checks = 1;
SET SESSION foreign_key_checks = 1;
SELECT 'products' AS tbl, COUNT(*) AS `rows` FROM products
UNION ALL SELECT 'product_variants', COUNT(*) FROM product_variants
UNION ALL SELECT 'customers', COUNT(*) FROM customers
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'ordered_products', COUNT(*) FROM ordered_products
UNION ALL SELECT 'payments', COUNT(*) FROM payments
UNION ALL SELECT 'order_status_history', COUNT(*) FROM order_status_history;
