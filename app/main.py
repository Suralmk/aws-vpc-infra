from fastapi import Depends, FastAPI, HTTPException
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from config import APP_NAME, APP_VERSION
from database import get_db
from health import run_infrastructure_checks

app = FastAPI(
    title="Infrastructure Health API",
    description="Health checks for the aws-vpc-infra three-tier VPC stack.",
    version=APP_VERSION,
)


@app.get("/health")
async def health(db: Session = Depends(get_db)):
    try:
        report = run_infrastructure_checks(db)
    except SQLAlchemyError as exc:
        raise HTTPException(
            status_code=503,
            detail={
                "status": "unhealthy",
                "services": {
                    "application": {"status": "healthy", "name": APP_NAME, "version": APP_VERSION},
                    "database": {"status": "disconnected", "error": str(exc)},
                },
            },
        ) from exc

    if report["status"] != "healthy":
        raise HTTPException(status_code=503, detail=report)

    return report


@app.get("/db-check")
async def db_check(db: Session = Depends(get_db)):
    try:
        result = db.execute(text("SELECT NOW()"))
    except SQLAlchemyError as exc:
        raise HTTPException(
            status_code=503,
            detail={"status": "disconnected", "error": str(exc)},
        ) from exc

    return {
        "status": "connected",
        "timestamp": str(result.scalar()),
    }
