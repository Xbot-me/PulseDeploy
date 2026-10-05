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

## 6. Measured under load (benchmark L-002, 2 vCPU / 4 GB, Amazon Linux 2023, small dataset)

Run: `loadtest/run.sh --profile breakpoint --time-scale 0.25` against the `small` profile (10,000 orders, 100,000
behaviour events), up to 150 virtual staff acting four times faster than a person (roughly 600 ordinary staff), about
28 minutes, rate limits lifted with `pulse-lt throttles off`. Result: **PASS**, 54,598 requests, 0 failures, slowest
endpoint p95 670 ms (admin dashboard), so no breakpoint was found. Server side (`pulse-lt record`):

* CPU averaged 25% and **peaked at 97%** (2 vCPU, load average 4.6). Memory peaked at 1.3 GB of 3.9 GB, no swap, no disk
  I/O wait, InnoDB buffer pool hit ratio 1.0. The PHP pool reached its 12-worker cap (13 processes, 456 MB).
* nginx request time, API (loopback, what the admin and storefront call): p50 86 ms, p95 329 ms, p99 620 ms.
* MariaDB ran 396,473 queries, **611 slower than 200 ms, and the five worst are the same query** (0.59 to 0.71 s each):

```sql
select product_id, sum(qty) as total_units from `ordered_products`
where exists (select * from `orders` where `ordered_products`.`order_id` = `orders`.`id` and ...live...)
  and `is_gift` = 0 group by `product_id` order by `total_units` desc limit 5
```

  This is `DashboardController` "Top selling products" (`OrderedProduct::...->whereHas('order', fn ($q) => $q->live())`).
  The same file's `total_purchased_unit` sum uses the same `whereHas`. A correlated `EXISTS` per `ordered_products` row
  is what costs the time, and it grows with the table (the dashboard took 3.5 to 4.5 s per request with 200,000 orders).
* **Redis saw 657 commands in 53 minutes and 3 hits**: the admin endpoints are not cached at all.

Suggested next changes (each measurable with the same benchmark):

1. Rewrite both dashboard aggregates as a join: `ordered_products` JOIN `orders` ON orders.id = ordered_products.order_id
   WHERE orders.<live conditions> AND ordered_products.is_gift = 0 GROUP BY product_id, and make sure
   `ordered_products(order_id, product_id, qty)` is covered by an index (check with EXPLAIN on the `medium` profile).
2. Cache the whole dashboard payload per store for 30 to 60 seconds (Redis is deployed and idle). With 20 or more staff
   opening the dashboard, every one of them currently runs these queries.
3. Re-run the same benchmark on the `medium` profile (200,000 orders) and compare with `pulse-lt diff`.

## 7. Benchmark L-003: the `medium` dataset (200,000 orders, 500,000 order lines) breaks the order list at about 10 users

Same server, same test as L-002 (breakpoint, `--time-scale 0.25`), only the data differs. The run ended at the first step:
676 requests, 0 failed, but p95 17,000 ms (limit 1,500 ms). CPU reached 100% (load average 7.6), 81 temporary tables
went to disk, and the nginx times for the loopback API were p50 4.5 s, p95 13.6 s. MariaDB: 4,346 queries, 496 slower
than 200 ms, and the worst five (6.5 to 6.6 s each) are one query:

```sql
select COALESCE(SUM(qty), 0) AS units, COUNT(DISTINCT NULLIF(product_id, 0)) AS products
from `ordered_products` where `order_id` in (select `orders`.`id` from `orders` where ...) and COALESCE(is_gift, 0) = 0
```

That is `OrderController::summarize()`, which runs on **every** `GET /admin/orders` (the list, page 2, each status filter)
and issues three aggregates over the whole filtered set: totals, the lines query above, and a `GROUP BY customer_phone`
for new vs repeat customers. The earlier rewrite (section 3.1) removed the timeouts but each list request still costs
several CPU-seconds at this size.

What I measured for it in isolation (sandbox, MariaDB 10.11, same `medium` data, warm cache, single caller, so a best case):

| Variant | Time |
|---|---|
| lines query as the app issues it | 2.5 s |
| same with a join instead of `IN (subselect)` | 2.3 s |
| same with a covering index on `ordered_products(order_id, is_gift, product_id, qty)` | 0.8 to 1.3 s |
| `GROUP BY customer_phone` (new vs repeat), plain | 1.05 s |
| same with an index on `orders(order_visibility, customer_phone)` | 2.7 to 3.3 s (worse) |
| orders count and sum with a covering index | 0.09 s |

So indexes and a join roughly halve the lines query, do not help the phone grouping, and leave a list request at about
1 to 2 s even for one user. On the VM, under concurrency, the same queries took 6.5 s. The cost is in computing the
summary over 200,000 orders and 500,000 lines on every request, not in a missing index.

Suggested change (CRM): stop computing the summary inline.

1. Serve the summary separately (`GET /admin/orders/summary`, or a `?summary=0` flag on the list) so the table renders
   immediately and the figures arrive when ready.
2. Cache the summary per filter set in Redis for 30 to 60 s, with a version key bumped on order writes if exactness
   matters. Redis recorded 113 commands during the whole run: it is idle.
3. Keep the covering index on `ordered_products` (it helps whatever else is done) and use `is_gift = 0` (the column is
   `NOT NULL DEFAULT 0`, so `COALESCE(is_gift, 0)` only prevents index use).
4. Re-run benchmark L-003 after the change and compare with `pulse-lt diff`. Target: the list under 500 ms at p95 for 20
   staff on the `medium` profile.

The dashboard (p50 13 s in this run) has the same shape and needs the same treatment (cache the payload; section 6).

## 8. After CRM commit 6239cb9 (sandbox re-measure, `medium` profile, 200,000 orders)

Migration `2026_10_15_000001_add_reporting_indexes` and `tenants:migrate` ran without errors (13 s on the 200,000-order tenant).
Single requests through the API (MariaDB 10.11, warm database, `CACHE_STORE=file`):

| Request | First call after the cache expired | Cached |
|---|---|---|
| `GET /admin/orders?per_page=20` | 5.1 s (very first call), 2.3 s (other filters) | 0.13 to 0.17 s |
| `GET /admin/dashboard` | 2.9 s | 0.18 s |

So the cached path is fast, and a request that finds the cache empty still pays 2 to 3 seconds. One thing to fix in
`LargeStoreCache::remember()`: it uses a plain `Cache::remember`, so when the 30-second entry expires **every concurrent
request recomputes it at the same moment** (a cache stampede). Twenty staff opening the dashboard right after expiry run
twenty copies of the heavy query at once, which is exactly the load that saturated both CPUs in benchmark L-003. Suggested:
take a short lock around the compute (`Cache::lock(...)->block(...)` or `Cache::flexible()` / a stale-while-revalidate
entry) so one request recomputes while the others serve the previous value. The benchmark will show whether it matters:
compare `pulse-lt record` runs before and after.

Deploy note for PulseDeploy users: `migrate` only migrates the central database. `pulse deploy api` now also runs
`tenants:migrate` when the application has it, otherwise existing stores never receive migrations like this one.

## 9. Benchmark L-004 on the VM: CRM 288396a (indexes + cache + no stampede), `medium` profile

Same test as L-003. **PASS: 55,800 requests, 0 failed, worst p95 790 ms** (L-003: 17,000 ms), 150 users at four times speed
for 37 minutes, no breakpoint found. Orders list p95 360 ms, dashboard p95 600 ms (p99 2,000 ms), orders by status p95 790 ms.
Redis 29,372 commands, 13,188 hits, 16 misses: the cache is doing its job.

What remains, from the slow-query log (1,474 queries over 200 ms in 37 minutes, all cache refreshes):

* `select COALESCE(SUM(c = 1), 0) AS fresh, COALESCE(SUM(c > 1), 0) AS repeaters from (select customer_phone, COUNT(*) ...)`
  1.9 to 3.6 s, and the order-summary lines query (`SUM(qty)`, `COUNT(DISTINCT product_id)`) 2.2 to 2.3 s. With 103 temporary
  tables written to disk during the run.
* The p99 tail (dashboard 2.0 s, orders by status 1.5 s) is whoever lands on a refresh, while a refresh is also using one core.

Ideas, in order of effort:

1. Refresh in the background instead of inside a user request: the Laravel scheduler already runs every minute on the
   server (`pulse-scheduler.timer`), so a scheduled command can warm the default dashboard and order-list summaries for
   large stores, and nobody waits for them.
2. For stores far above `cache_over_orders` (for example over 100,000 orders) use a longer `cache_seconds` (60 to 120).
3. Make the new-versus-repeat-customer figure cheaper (it groups the whole orders table by phone every time) or compute it
   from a maintained counter.
