-- Initial schema for Velocity Dispatch.
--
-- Notes on choices that are worth defending in an interview:
--  * lat/lon stored as plain double precision, not PostGIS geography, to
--    keep the local dev stack (docker-compose) dependency-free. The
--    "next step at scale" section of the README calls out exactly where
--    PostGIS ST_DWithin + a GiST index would replace the in-process
--    haversine scan in dispatch-core::geo.
--  * status columns are plain text with a CHECK constraint rather than a
--    Postgres ENUM type — enums are painful to migrate (ALTER TYPE ...
--    ADD VALUE can't run inside a transaction on older PG versions);
--    a CHECK constraint gets 95% of the safety with a trivial migration path.

CREATE TABLE IF NOT EXISTS drivers (
    id          UUID PRIMARY KEY,
    name        TEXT NOT NULL,
    lat         DOUBLE PRECISION NOT NULL,
    lon         DOUBLE PRECISION NOT NULL,
    status      TEXT NOT NULL DEFAULT 'available'
                CHECK (status IN ('available', 'busy', 'offline')),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_drivers_status ON drivers (status);

CREATE TABLE IF NOT EXISTS orders (
    id            UUID PRIMARY KEY,
    pickup_lat    DOUBLE PRECISION NOT NULL,
    pickup_lon    DOUBLE PRECISION NOT NULL,
    dropoff_lat   DOUBLE PRECISION NOT NULL,
    dropoff_lon   DOUBLE PRECISION NOT NULL,
    status        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'assigned', 'picked_up', 'delivered', 'cancelled')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_status ON orders (status);

CREATE TABLE IF NOT EXISTS assignments (
    id            UUID PRIMARY KEY,
    order_id      UUID NOT NULL REFERENCES orders (id),
    driver_id     UUID NOT NULL REFERENCES drivers (id),
    distance_km   DOUBLE PRECISION NOT NULL,
    assigned_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_assignments_order ON assignments (order_id);
CREATE INDEX IF NOT EXISTS idx_assignments_driver ON assignments (driver_id);
