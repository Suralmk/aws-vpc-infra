from sqlalchemy import text
from sqlalchemy.orm import Session

from config import APP_NAME, APP_VERSION, DATABASE_URL


def check_application() -> dict:
    return {
        "status": "healthy",
        "name": APP_NAME,
        "version": APP_VERSION,
    }


def check_database(db: Session) -> dict:
    result = db.execute(text("SELECT NOW()"))
    timestamp = result.scalar()
    return {
        "status": "connected",
        "timestamp": str(timestamp),
        "endpoint": _masked_database_url(),
    }


def _masked_database_url() -> str:
    if "@" not in DATABASE_URL:
        return "configured"
    return DATABASE_URL.split("@", maxsplit=1)[-1]


def run_infrastructure_checks(db: Session) -> dict:
    services = {
        "application": check_application(),
        "database": check_database(db),
    }
    all_healthy = all(
        service.get("status") in {"healthy", "connected"} for service in services.values()
    )
    return {
        "status": "healthy" if all_healthy else "unhealthy",
        "services": services,
    }
