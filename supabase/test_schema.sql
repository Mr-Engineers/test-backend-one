-- Projekt COMMERCE · bliźniacze tabele dla test-backend-one (prefiks test_)
-- Te same schematy (warehouse, shops) co one-backend, ale osobne obiekty z prefiksem test_:
-- warehouse.test_products, shops.test_biuromax, warehouse.test_receive_purchase_order(...), ...
-- Nie dotyka tabel produkcyjnych. Wymaga, żeby schematy warehouse i shops już istniały (krok 1 one-backend)
-- i były na liście Exposed schemas w Supabase.
-- Wklej całość do Supabase → SQL Editor → Run.
BEGIN;

CREATE SCHEMA IF NOT EXISTS warehouse;
CREATE SCHEMA IF NOT EXISTS shops;

-- ===== warehouse (test_) =====

CREATE TYPE warehouse.test_po_status AS ENUM ('open', 'received', 'cancelled');

CREATE TYPE warehouse.test_movement_type AS ENUM (
  'receipt',        -- przyjęcie dostawy z purchase order (POST /purchase-orders/{id}/receive)
  'issue',          -- wydanie z magazynu
  'adjustment',     -- korekta ręczna (delta + reason)
  'scenario_reset'  -- POST /admin/scenarios/{id}/load
);

-- ---------------------------------------------------------------------------
-- Katalog produktów (SKU wspólne z marketplace)
-- ---------------------------------------------------------------------------

CREATE TABLE warehouse.test_products (
  sku               TEXT        PRIMARY KEY,
  name              TEXT        NOT NULL,
  unit              TEXT        NOT NULL,                     -- szt, karton, …
  reorder_threshold INTEGER     NOT NULL CHECK (reorder_threshold >= 0),
  target_level      INTEGER     NOT NULL CHECK (target_level > 0),
  max_order_qty     INTEGER     CHECK (max_order_qty > 0),    -- opcjonalny sufit dla polityk proxy (qty_ratio)
  active            BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (target_level >= reorder_threshold)
);

-- Stan fizyczny. on_order NIE jest przechowywany — liczony z otwartych purchase orders (brak dryfu).
CREATE TABLE warehouse.test_stock_levels (
  sku        TEXT        PRIMARY KEY REFERENCES warehouse.test_products (sku) ON DELETE CASCADE,
  on_hand    INTEGER     NOT NULL DEFAULT 0 CHECK (on_hand >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Dostawcy (sprzedawcy z marketplace) — profil do enrichmentu proxy (GET /merchants/{id})
-- ---------------------------------------------------------------------------

CREATE TABLE warehouse.test_suppliers (
  merchant_id          TEXT        PRIMARY KEY,               -- mer_biuromax
  name                 TEXT        NOT NULL,
  domain               TEXT        NOT NULL UNIQUE,
  country              CHAR(2)     NOT NULL CHECK (country ~ '^[A-Z]{2}$'),
  domain_registered_at DATE        NOT NULL,
  verified             BOOLEAN     NOT NULL DEFAULT FALSE,
  reputation_score     NUMERIC(3,2) CHECK (reputation_score BETWEEN 0 AND 1),  -- NULL = brak opinii
  reviews_count        INTEGER     NOT NULL DEFAULT 0 CHECK (reviews_count >= 0),
  offers_table         TEXT        NOT NULL UNIQUE,           -- np. 'shops.test_biuromax'
  scenario_id          TEXT,                                  -- NULL = katalog bazowy
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((reputation_score IS NULL) = (reviews_count = 0))
);

-- ---------------------------------------------------------------------------
-- Purchase orders — rejestr zamówień złożonych w marketplace (POST /purchase-orders)
-- ---------------------------------------------------------------------------

CREATE TABLE warehouse.test_purchase_orders (
  id                   TEXT          PRIMARY KEY,             -- po_3b91
  sku                  TEXT          NOT NULL REFERENCES warehouse.test_products (sku),
  quantity             INTEGER       NOT NULL CHECK (quantity > 0),
  unit_price           NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
  currency             CHAR(3)       NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  total                NUMERIC(14,2) GENERATED ALWAYS AS (unit_price * quantity) STORED,
  total_eur            NUMERIC(14,2),                         -- przeliczenie dla reguł/budżetów (pole total_eur)
  status               warehouse.test_po_status NOT NULL DEFAULT 'open',
  marketplace_order_id TEXT          NOT NULL UNIQUE,         -- ord_8f2c
  merchant_id          TEXT          NOT NULL REFERENCES warehouse.test_suppliers (merchant_id),
  -- idempotencja: ten sam klucz + ten sam hash body → ten sam wynik; inny hash → 409 idempotency_conflict
  idempotency_key      UUID          NOT NULL UNIQUE,
  request_hash         TEXT          NOT NULL,
  -- korelacja z audytem proxy (nagłówki informacyjne)
  request_id           TEXT,                                  -- X-Request-Id
  on_behalf_of         TEXT,                                  -- X-On-Behalf-Of (agent_id)
  created_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
  received_at          TIMESTAMPTZ,
  cancelled_at         TIMESTAMPTZ,
  CHECK ((status = 'received') = (received_at IS NOT NULL)),
  CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL))
);

CREATE INDEX test_purchase_orders_sku_open_idx ON warehouse.test_purchase_orders (sku) WHERE status = 'open';
CREATE INDEX test_purchase_orders_sku_created_idx ON warehouse.test_purchase_orders (sku, created_at DESC);
CREATE INDEX test_purchase_orders_request_id_idx ON warehouse.test_purchase_orders (request_id);

-- ---------------------------------------------------------------------------
-- Historia ruchów magazynowych (append-only)
-- ---------------------------------------------------------------------------

CREATE TABLE warehouse.test_stock_movements (
  id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sku               TEXT        NOT NULL REFERENCES warehouse.test_products (sku),
  movement_type     warehouse.test_movement_type NOT NULL,
  delta             INTEGER     NOT NULL CHECK (delta <> 0 OR movement_type = 'scenario_reset'),
  on_hand_after     INTEGER     NOT NULL CHECK (on_hand_after >= 0),
  purchase_order_id TEXT        REFERENCES warehouse.test_purchase_orders (id),
  reason            TEXT,
  actor             TEXT        NOT NULL,                     -- operator / konto serwisowe / agent_id
  request_id        TEXT,                                     -- X-Request-Id
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((movement_type = 'receipt') = (purchase_order_id IS NOT NULL)),
  CHECK (movement_type <> 'adjustment' OR reason IS NOT NULL)
);

CREATE INDEX test_stock_movements_sku_created_idx ON warehouse.test_stock_movements (sku, created_at DESC);

CREATE FUNCTION warehouse.test_forbid_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END $$;

CREATE TRIGGER test_stock_movements_append_only
  BEFORE UPDATE OR DELETE ON warehouse.test_stock_movements
  FOR EACH ROW EXECUTE FUNCTION warehouse.test_forbid_mutation();

-- ---------------------------------------------------------------------------
-- Widoki pod API
-- ---------------------------------------------------------------------------

CREATE VIEW warehouse.test_stock_availability AS
SELECT
  p.sku,
  p.name,
  p.unit,
  COALESCE(s.on_hand, 0)                                  AS on_hand,
  COALESCE(o.on_order, 0)                                 AS on_order,
  p.reorder_threshold,
  p.target_level,
  GREATEST(p.target_level - COALESCE(s.on_hand, 0) - COALESCE(o.on_order, 0), 0) AS qty_needed,
  o.last_order_at
FROM warehouse.test_products p
LEFT JOIN warehouse.test_stock_levels s ON s.sku = p.sku
LEFT JOIN (
  SELECT sku, SUM(quantity)::INTEGER AS on_order, MAX(created_at) AS last_order_at
  FROM warehouse.test_purchase_orders
  WHERE status = 'open'
  GROUP BY sku
) o ON o.sku = p.sku
WHERE p.active;

CREATE VIEW warehouse.test_low_stock AS
SELECT sku, name, unit, on_hand, on_order, reorder_threshold, target_level, qty_needed
FROM warehouse.test_stock_availability
WHERE on_hand + on_order < reorder_threshold;

-- ---------------------------------------------------------------------------
-- Operacje atomowe
-- ---------------------------------------------------------------------------

-- POST /purchase-orders/{id}/receive (RPC: POST /rpc/test_receive_purchase_order)
CREATE FUNCTION warehouse.test_receive_purchase_order(p_id TEXT, p_actor TEXT, p_request_id TEXT DEFAULT NULL)
RETURNS warehouse.test_purchase_orders LANGUAGE plpgsql AS $$
DECLARE
  po        warehouse.test_purchase_orders;
  new_level INTEGER;
BEGIN
  UPDATE warehouse.test_purchase_orders
     SET status = 'received', received_at = now()
   WHERE id = p_id AND status = 'open'
  RETURNING * INTO po;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'purchase order % not found or not open', p_id;
  END IF;

  INSERT INTO warehouse.test_stock_levels AS s (sku, on_hand) VALUES (po.sku, po.quantity)
  ON CONFLICT (sku) DO UPDATE SET on_hand = s.on_hand + EXCLUDED.on_hand, updated_at = now()
  RETURNING s.on_hand INTO new_level;

  INSERT INTO warehouse.test_stock_movements (sku, movement_type, delta, on_hand_after, purchase_order_id, actor, request_id)
  VALUES (po.sku, 'receipt', po.quantity, new_level, po.id, p_actor, p_request_id);

  RETURN po;
END $$;

-- ===== shops (test_) =====
-- Jedna tabela = jeden sklep = jego oferty. Profil sprzedawcy w warehouse.test_suppliers.

-- Polska · BiuroMax · biuromax.pl · katalog bazowy, happy_path
CREATE TABLE shops.test_biuromax (
  offer_id      TEXT          PRIMARY KEY,
  merchant_id   TEXT          NOT NULL DEFAULT 'mer_biuromax' CHECK (merchant_id = 'mer_biuromax')
                              REFERENCES warehouse.test_suppliers (merchant_id),
  sku           TEXT          NOT NULL,                     -- wspólny katalog z warehouse.test_products
  product_name  TEXT          NOT NULL,
  unit_price    NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
  currency      CHAR(3)       NOT NULL DEFAULT 'PLN' CHECK (currency ~ '^[A-Z]{3}$'),
  available_qty INTEGER       NOT NULL CHECK (available_qty >= 0),
  ships_from    CHAR(2)       NOT NULL CHECK (ships_from ~ '^[A-Z]{2}$'),
  delivery_days INTEGER       NOT NULL CHECK (delivery_days >= 0),
  description   TEXT          NOT NULL DEFAULT '',
  scenario_id   TEXT,                                       -- NULL = katalog bazowy
  active        BOOLEAN       NOT NULL DEFAULT TRUE,
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT now()
);
CREATE INDEX test_biuromax_sku_idx ON shops.test_biuromax (sku) WHERE active;

-- Rosja · OfisTorg · ofistorg.ru · scenariusz sanctioned_country
CREATE TABLE shops.test_ofistorg (
  offer_id      TEXT          PRIMARY KEY,
  merchant_id   TEXT          NOT NULL DEFAULT 'mer_ofistorg' CHECK (merchant_id = 'mer_ofistorg')
                              REFERENCES warehouse.test_suppliers (merchant_id),
  sku           TEXT          NOT NULL,
  product_name  TEXT          NOT NULL,
  unit_price    NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
  currency      CHAR(3)       NOT NULL DEFAULT 'PLN' CHECK (currency ~ '^[A-Z]{3}$'),
  available_qty INTEGER       NOT NULL CHECK (available_qty >= 0),
  ships_from    CHAR(2)       NOT NULL CHECK (ships_from ~ '^[A-Z]{2}$'),
  delivery_days INTEGER       NOT NULL CHECK (delivery_days >= 0),
  description   TEXT          NOT NULL DEFAULT '',
  scenario_id   TEXT,
  active        BOOLEAN       NOT NULL DEFAULT TRUE,
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT now()
);
CREATE INDEX test_ofistorg_sku_idx ON shops.test_ofistorg (sku) WHERE active;

-- Indie · CheapDeals · cheap-office-deals.in · scenariusz foreign_cheapest
CREATE TABLE shops.test_cheapdeals (
  offer_id      TEXT          PRIMARY KEY,
  merchant_id   TEXT          NOT NULL DEFAULT 'mer_cheapdeals' CHECK (merchant_id = 'mer_cheapdeals')
                              REFERENCES warehouse.test_suppliers (merchant_id),
  sku           TEXT          NOT NULL,
  product_name  TEXT          NOT NULL,
  unit_price    NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
  currency      CHAR(3)       NOT NULL DEFAULT 'PLN' CHECK (currency ~ '^[A-Z]{3}$'),
  available_qty INTEGER       NOT NULL CHECK (available_qty >= 0),
  ships_from    CHAR(2)       NOT NULL CHECK (ships_from ~ '^[A-Z]{2}$'),
  delivery_days INTEGER       NOT NULL CHECK (delivery_days >= 0),
  description   TEXT          NOT NULL DEFAULT '',
  scenario_id   TEXT,
  active        BOOLEAN       NOT NULL DEFAULT TRUE,
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT now()
);
CREATE INDEX test_cheapdeals_sku_idx ON shops.test_cheapdeals (sku) WHERE active;

-- Niemcy · OfficeHub · officehub.de · katalog bazowy
CREATE TABLE shops.test_officehub (
  offer_id      TEXT          PRIMARY KEY,
  merchant_id   TEXT          NOT NULL DEFAULT 'mer_officehub' CHECK (merchant_id = 'mer_officehub')
                              REFERENCES warehouse.test_suppliers (merchant_id),
  sku           TEXT          NOT NULL,
  product_name  TEXT          NOT NULL,
  unit_price    NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
  currency      CHAR(3)       NOT NULL DEFAULT 'PLN' CHECK (currency ~ '^[A-Z]{3}$'),
  available_qty INTEGER       NOT NULL CHECK (available_qty >= 0),
  ships_from    CHAR(2)       NOT NULL CHECK (ships_from ~ '^[A-Z]{2}$'),
  delivery_days INTEGER       NOT NULL CHECK (delivery_days >= 0),
  description   TEXT          NOT NULL DEFAULT '',
  scenario_id   TEXT,
  active        BOOLEAN       NOT NULL DEFAULT TRUE,
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT now()
);
CREATE INDEX test_officehub_sku_idx ON shops.test_officehub (sku) WHERE active;

-- USA · PrintWorks · printworks-usa.com · scenariusz indirect_injection
CREATE TABLE shops.test_printworks (
  offer_id      TEXT          PRIMARY KEY,
  merchant_id   TEXT          NOT NULL DEFAULT 'mer_printworks' CHECK (merchant_id = 'mer_printworks')
                              REFERENCES warehouse.test_suppliers (merchant_id),
  sku           TEXT          NOT NULL,
  product_name  TEXT          NOT NULL,
  unit_price    NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
  currency      CHAR(3)       NOT NULL DEFAULT 'PLN' CHECK (currency ~ '^[A-Z]{3}$'),
  available_qty INTEGER       NOT NULL CHECK (available_qty >= 0),
  ships_from    CHAR(2)       NOT NULL CHECK (ships_from ~ '^[A-Z]{2}$'),
  delivery_days INTEGER       NOT NULL CHECK (delivery_days >= 0),
  description   TEXT          NOT NULL DEFAULT '',
  scenario_id   TEXT,
  active        BOOLEAN       NOT NULL DEFAULT TRUE,
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT now()
);
CREATE INDEX test_printworks_sku_idx ON shops.test_printworks (sku) WHERE active;

CREATE VIEW shops.test_offers AS
SELECT offer_id, merchant_id, sku, product_name, unit_price, currency, available_qty, ships_from, delivery_days, description, scenario_id, active FROM shops.test_biuromax
UNION ALL
SELECT offer_id, merchant_id, sku, product_name, unit_price, currency, available_qty, ships_from, delivery_days, description, scenario_id, active FROM shops.test_ofistorg
UNION ALL
SELECT offer_id, merchant_id, sku, product_name, unit_price, currency, available_qty, ships_from, delivery_days, description, scenario_id, active FROM shops.test_cheapdeals
UNION ALL
SELECT offer_id, merchant_id, sku, product_name, unit_price, currency, available_qty, ships_from, delivery_days, description, scenario_id, active FROM shops.test_officehub
UNION ALL
SELECT offer_id, merchant_id, sku, product_name, unit_price, currency, available_qty, ships_from, delivery_days, description, scenario_id, active FROM shops.test_printworks;

-- ===== uprawnienia (tylko obiekty test_) =====
-- Dostęp ma tylko service_role. Uprawnienia nadawane jawnie per obiekt, żeby nie ruszać tabel produkcyjnych.

GRANT USAGE ON SCHEMA warehouse, shops TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON
  warehouse.test_products,
  warehouse.test_stock_levels,
  warehouse.test_suppliers,
  warehouse.test_purchase_orders,
  shops.test_biuromax,
  shops.test_ofistorg,
  shops.test_cheapdeals,
  shops.test_officehub,
  shops.test_printworks
TO service_role;

-- Historia ruchów: tylko odczyt i dopisywanie (trigger i tak blokuje UPDATE/DELETE).
GRANT SELECT, INSERT ON warehouse.test_stock_movements TO service_role;
REVOKE UPDATE, DELETE ON warehouse.test_stock_movements FROM service_role;
GRANT USAGE, SELECT ON SEQUENCE warehouse.test_stock_movements_id_seq TO service_role;

GRANT SELECT ON warehouse.test_stock_availability, warehouse.test_low_stock, shops.test_offers TO service_role;

REVOKE EXECUTE ON FUNCTION warehouse.test_forbid_mutation() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION warehouse.test_receive_purchase_order(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION warehouse.test_receive_purchase_order(TEXT, TEXT, TEXT) TO service_role;

-- Obrona w głąb: RLS bez polityk = brak dostępu dla anon/authenticated. service_role ma BYPASSRLS.
ALTER TABLE warehouse.test_products        ENABLE ROW LEVEL SECURITY;
ALTER TABLE warehouse.test_stock_levels    ENABLE ROW LEVEL SECURITY;
ALTER TABLE warehouse.test_suppliers       ENABLE ROW LEVEL SECURITY;
ALTER TABLE warehouse.test_purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE warehouse.test_stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE shops.test_biuromax            ENABLE ROW LEVEL SECURITY;
ALTER TABLE shops.test_ofistorg            ENABLE ROW LEVEL SECURITY;
ALTER TABLE shops.test_cheapdeals          ENABLE ROW LEVEL SECURITY;
ALTER TABLE shops.test_officehub           ENABLE ROW LEVEL SECURITY;
ALTER TABLE shops.test_printworks          ENABLE ROW LEVEL SECURITY;

ALTER VIEW warehouse.test_stock_availability SET (security_invoker = true);
ALTER VIEW warehouse.test_low_stock          SET (security_invoker = true);
ALTER VIEW shops.test_offers                 SET (security_invoker = true);

NOTIFY pgrst, 'reload schema';
COMMIT;
