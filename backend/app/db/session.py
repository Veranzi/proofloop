from collections.abc import Iterator
from functools import lru_cache

from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import Session, sessionmaker

from app.config import get_settings


@lru_cache
def get_engine() -> Engine:
    # Small pool per instance: total connections = pool size x Cloud Run max instances.
    return create_engine(
        get_settings().database_url, pool_size=5, max_overflow=5, pool_pre_ping=True
    )


@lru_cache
def _session_factory() -> sessionmaker[Session]:
    return sessionmaker(bind=get_engine(), expire_on_commit=False)


def get_db() -> Iterator[Session]:
    """FastAPI dependency. Routes commit explicitly; anything uncommitted rolls back."""
    with _session_factory()() as session:
        yield session
