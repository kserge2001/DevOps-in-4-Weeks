"""QuickShop: one small API that runs the same on EC2, ECS, Lambda and EKS."""
import json
import os
from functools import lru_cache

import boto3
import psycopg
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from psycopg.rows import dict_row
from pydantic import BaseModel, Field

PLATFORM = os.environ.get("PLATFORM", "local")
HERE = os.path.dirname(os.path.abspath(__file__))

app = FastAPI(title="QuickShop")


@lru_cache
def db_credentials():
    """User and password: from Secrets Manager on AWS, from env vars locally."""
    secret_arn = os.environ.get("DB_SECRET_ARN")
    if secret_arn:
        secret = boto3.client("secretsmanager").get_secret_value(SecretId=secret_arn)
        values = json.loads(secret["SecretString"])
        return values["username"], values["password"]
    return os.environ["DB_USER"], os.environ["DB_PASSWORD"]


def connect():
    user, password = db_credentials()
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        dbname=os.environ.get("DB_NAME", "quickshop"),
        user=user,
        password=password,
        connect_timeout=5,
        row_factory=dict_row,
    )


SCHEMA = """
CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    price NUMERIC(8, 2) NOT NULL
);
CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    product_id INT NOT NULL REFERENCES products(id),
    quantity INT NOT NULL,
    total NUMERIC(10, 2) NOT NULL,
    platform TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""
SEED = [("Coffee mug", 12.50), ("T-shirt", 20.00), ("Sticker pack", 4.99)]
_schema_ready = False


def ensure_schema(conn):
    """Create the tables and the sample products the first time they're needed."""
    global _schema_ready
    if _schema_ready:
        return
    conn.execute(SCHEMA)
    if conn.execute("SELECT count(*) AS n FROM products").fetchone()["n"] == 0:
        with conn.cursor() as cur:
            cur.executemany("INSERT INTO products (name, price) VALUES (%s, %s)", SEED)
    conn.commit()
    _schema_ready = True


class OrderIn(BaseModel):
    product_id: int
    quantity: int = Field(gt=0, le=100)


@app.get("/")
def home():
    return FileResponse(os.path.join(HERE, "index.html"))


@app.get("/health")
def health():
    try:
        with connect() as conn:
            conn.execute("SELECT 1")
    except Exception as exc:
        raise HTTPException(503, f"database unreachable: {type(exc).__name__}")
    return {"status": "ok", "platform": PLATFORM}


@app.get("/api/products")
def products():
    with connect() as conn:
        ensure_schema(conn)
        rows = conn.execute("SELECT id, name, price FROM products ORDER BY id").fetchall()
    return [{**r, "price": float(r["price"])} for r in rows]


@app.post("/api/orders", status_code=201)
def create_order(order: OrderIn):
    with connect() as conn:
        ensure_schema(conn)
        product = conn.execute("SELECT name, price FROM products WHERE id = %s", (order.product_id,)).fetchone()
        if product is None:
            raise HTTPException(404, "product not found")
        total = product["price"] * order.quantity
        row = conn.execute(
            "INSERT INTO orders (product_id, quantity, total, platform) VALUES (%s, %s, %s, %s) RETURNING id",
            (order.product_id, order.quantity, total, PLATFORM),
        ).fetchone()
    return {"id": row["id"], "product": product["name"], "quantity": order.quantity,
            "total": float(total), "platform": PLATFORM}


@app.get("/api/orders/{order_id}")
def get_order(order_id: int):
    with connect() as conn:
        ensure_schema(conn)
        row = conn.execute(
            "SELECT o.id, p.name AS product, o.quantity, o.total, o.platform, o.created_at "
            "FROM orders o JOIN products p ON p.id = o.product_id WHERE o.id = %s",
            (order_id,),
        ).fetchone()
    if row is None:
        raise HTTPException(404, "order not found")
    return {**row, "total": float(row["total"])}
