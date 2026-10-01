# AvenTech CRM: scaling findings and fixes (brief for the CRM coding agent)

Source: load-test data generator in the PulseDeploy repo (`loadtest/seed/seed.sh`), run against the CRM
backend on MariaDB 10.11, one CPU core, PHP built-in server. Measured once; absolute numbers will differ
on other hardware, the shape (growth with order count) will not.

## 1. Finding

With realistic data, two admin endpoints get slower in proportion to the **total number of orders in the
store**, not the page size, and fail outright around 100,000 orders.

| Orders in store | `GET /api/v1/admin/orders` | `GET /api/v1/admin/dashboard` |
|---|---|---|
| 2,000 | 0.35 s | 0.58 s |
| 10,000 | 1.5 s | 2.5 s |
| 30,000 | 8.6 s | 8.0 s |
| 100,000 | HTTP 500, "Maximum execution time of 30 seconds exceeded" | same |

Products (5,000) and customers (20,000) lists were fast: 0.05 to 0.13 s. The problem is specific to orders,
and it is in application code, not in server tuning (PHP/MariaDB/Redis settings do not change it).

## 2. Root causes (all in `app/Http/Controllers/Api/V1/Admin/`)

### 2.1 `OrderController::index` (line ~57)
```php
$query = Order::with(['orderedProducts.product', 'payments', 'employeeOrders'])->orderByDesc('id');
...
$filtered = (clone $query)->get();          // loads EVERY matching order + all eager loads
$paginator = $query->paginate($perPage);    // the page itself is cheap
...
$phones = $filtered->groupBy('customer_phone')->map->count();
// summary: total_orders, total_value, total_units, total_products, new/repeat customers
// are all computed in PHP over $filtered
```
The slow-query log shows `select * from ordered_products where order_id in (1, 2, ... 100000)`:
200,573 rows and 15 MB sent for one request, plus the same for payments and employee orders, then hydrated
into models.

### 2.2 `DashboardController::index` (lines ~20-22, 56, 72)
```php
$products = Product::with('variants')->get();
$orders   = Order::with(['orderedProducts', 'payments'])->get();   // every order, every line
$payments = Payment::orderBy('created_at')->get();                 // every payment
$expenses = Expense::whereYear('created_at', $year)->get();
```
Then status counts, payment-method totals, 12-month charts and the revenue/expense chart are all computed
by grouping and filtering these collections in PHP.

### 2.3 Indexes
`orders` has only: primary key, `order_no` unique, `applied_discount_id` foreign key. Nothing on
`order_status`, `payment_status`, `order_visibility`, `created_at`, `customer_phone`. (Check the other
tables the same way: `payments(order_id, created_at)`, `ordered_products(order_id, product_id)`,
`order_status_history(order_id)`; the schema dump from a migrated tenant is the source of truth.)

## 3. Suggested fixes

Behaviour and response shapes must stay identical (the admin app consumes them). Do the work in the database.

### 3.1 Order list summary: aggregate in SQL
Build the summary from one aggregate query over the **filtered** set, without eager loads:
```php
$base = Order::query()/* same where() filters as above, no with(), no orderBy */;

$agg = (clone $base)->selectRaw('COUNT(*) AS total_orders, COALESCE(SUM(grand_total_amount),0) AS total_value')->first();

$units = OrderedProduct::whereIn('order_id', (clone $base)->select('id'))
    ->where('is_gift', false)
    ->selectRaw('COALESCE(SUM(qty),0) AS units, COUNT(DISTINCT product_id) AS products')->first();

$phoneCounts = (clone $base)->select('customer_phone')->selectRaw('COUNT(*) AS c')
    ->groupBy('customer_phone');
$new    = DB::query()->fromSub($phoneCounts, 'p')->where('c', 1)->count();
$repeat = DB::query()->fromSub($phoneCounts, 'p')->where('c', '>', 1)->count();
```
Keep the paginated query with its eager loads (that part is fine; also `->with('orderedProducts.product')`
is only for 15-100 rows). Add a feature test that compares the old summary and the new one on a seeded store.
The `whereIn(... select id)` can be a join if MariaDB plans it poorly; check with `EXPLAIN`.

Optional: if exact figures are not needed on every page load, cache the summary per filter set in Redis
for 30 to 60 s.

### 3.2 Dashboard: aggregate in SQL
Replace each collection pass with a grouped query:
- status counts: `Order::select('order_status', DB::raw('COUNT(*) c'))->groupBy('order_status')`
- payment-method totals: `Payment::select('payment_method', DB::raw('SUM(paid_amount) s'))->groupBy('payment_method')`
- 12-month chart and revenue-vs-expense: `GROUP BY DATE_FORMAT(created_at, '%Y-%m')` with a `WHERE created_at >= ?`
  lower bound (so an index on `payments.created_at` is used); same for `expenses` (replace `whereYear()`, which
  cannot use an index, with a `>= start AND < end` range)
- stock: `SUM(available_stock)` queries on `products` and `product_variants`
- anything else on the page that loops over `$orders`/`$payments`: same treatment

Cache the whole dashboard payload for 30 to 60 s per store (Redis is already deployed). Staff see numbers that are
at most a minute old, which is normal for a dashboard.

### 3.3 Indexes (new tenant migration, `Schema::table`, guarded so it is idempotent)
Verify each against `EXPLAIN` on a seeded store before keeping it.
```
orders:           (order_visibility, id)              -- the default list: visibility != 'trash' ORDER BY id DESC
                  (order_status, id), (payment_status, id)
                  (created_at), (customer_phone)
payments:         (order_id), (created_at)
ordered_products: (order_id), (product_id)            -- skip any that already exist as FK indexes
order_status_history: (order_id)
```
`search` uses `LIKE '%term%'` on `order_no`, `customer_full_name`, `customer_phone`, which no B-tree index helps.
If search must scale, switch to a prefix match (`term%`) for `order_no`/phone, or add a FULLTEXT index on
the name; decide with product owners.

### 3.4 Same pattern elsewhere
Grep for `->get()` / `->all()` followed by `groupBy`, `sum`, `count`, `filter` on large tables
(orders, payments, ordered_products, customers, order_status_history): reports, exports, inventory, blocklist
checks. Each is a candidate for the same fix. Exports should stream with `chunkById()` / `lazy()`.

## 4. How to reproduce and verify

The generator lives in PulseDeploy (`loadtest/seed/`). It creates a separate test store and marks everything it
adds, so it is safe next to real data, and `--purge` removes it.

```bash
# on a machine with the CRM and a local MySQL/MariaDB
sudo bash loadtest/seed/seed.sh --store loadtest --create-store              # 100k orders (about 10 s)
sudo bash loadtest/seed/seed.sh --store loadtest --purge --yes
sudo bash loadtest/seed/seed.sh --store loadtest --orders 10000 --customers 5000 --products 1000 --yes
```
Admin login: `POST /api/v1/admin/login` with header `X-Store-Subdomain: loadtest` (credentials are in
`/root/loadtest-store-credentials.txt` after `--create-store`). Time `GET /admin/orders` and `GET /admin/dashboard`
with the returned bearer token.

Turn on the slow-query log while testing:
`SET GLOBAL slow_query_log=1, long_query_time=0.3, slow_query_log_file='/tmp/slow.log';`

**Acceptance targets** at 100,000 orders (suggested): `/admin/orders` and `/admin/dashboard` under 500 ms on the
first call, under 100 ms cached; no query returning more than a page of rows (check `Rows_sent` in the slow log);
response JSON identical to before on the same data (compare summary fields).

Then confirm under traffic: `bash loadtest/run.sh ... --store loadtest --profile average` should pass its p95
limit (1500 ms default) with the seeded store. The earlier breakpoint run only looked good because the database was empty.

## 5. Other items noticed (lower priority)
- Every request costs a central `stores` lookup, a tenant connection, a Sanctum token lookup and a
  `last_used_at` UPDATE. A cache for the store lookup and dropping the `last_used_at` write were tried on a
  branch and made no measurable difference; do not spend more time there.
- The nginx admin-host login path (`/api/auth/login`) has no `limit_req` (the API host has one). Hardening item, in PulseDeploy.
