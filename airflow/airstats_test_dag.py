from datetime import timedelta
import urllib.request

import boto3
import pendulum
from botocore.exceptions import ClientError

from airflow import DAG
from airflow.providers.standard.operators.empty import EmptyOperator
from airflow.providers.standard.operators.python import PythonOperator
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.providers.amazon.aws.operators.ecs import EcsRunTaskOperator


# ============================================================
# DAG CONFIGURATION
# ============================================================

BERLIN_TZ = pendulum.timezone("Europe/Berlin")

default_args = {
    "owner": "airstats",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
}


# ============================================================
# SOURCE CONFIGURATION
# ============================================================

SOURCE_BUCKET = "airstats-adewale"
SOURCE_PREFIX = "raw"

OURAIRPORTS_BASE_URL = (
    "https://raw.githubusercontent.com/"
    "davidmegginson/ourairports-data/main"
)

SOURCE_FILES = [
    "airports.csv",
    "runways.csv",
    "airport-frequencies.csv",
    "airport-comments.csv",
    "countries.csv",
    "regions.csv",
    "navaids.csv",
]


# ============================================================
# SNOWFLAKE LOAD CONFIGURATION
# ============================================================

LOAD_CONFIG = {
    "airports": {
        "table": "AIRPORTS",
        "file": "airports.csv",
    },
    "runways": {
        "table": "RUNWAYS",
        "file": "runways.csv",
    },
    "airport_frequencies": {
        "table": "AIRPORT_FREQUENCIES",
        "file": "airport-frequencies.csv",
    },
    "airport_comments": {
        "table": "AIRPORT_COMMENTS",
        "file": "airport-comments.csv",
    },
    "countries": {
        "table": "COUNTRIES",
        "file": "countries.csv",
    },
    "regions": {
        "table": "REGIONS",
        "file": "regions.csv",
    },
    "navaids": {
        "table": "NAVAIDS",
        "file": "navaids.csv",
    },
}


# ============================================================
# AIRFLOW RUN-DATE TEMPLATES
# ============================================================

RUN_DATE_TEMPLATE = (
    "{{ data_interval_end"
    ".in_timezone('Europe/Berlin')"
    ".strftime('%Y-%m-%d') }}"
)

DAILY_STAGE_PREFIX = (
    "year={{ data_interval_end"
    ".in_timezone('Europe/Berlin')"
    ".strftime('%Y') }}/"
    "month={{ data_interval_end"
    ".in_timezone('Europe/Berlin')"
    ".strftime('%m') }}/"
    "day={{ data_interval_end"
    ".in_timezone('Europe/Berlin')"
    ".strftime('%d') }}"
)


# ============================================================
# HELPER FUNCTIONS
# ============================================================

def build_daily_prefix(run_date: str) -> str:
    """
    Convert the Airflow run date into the partitioned S3 path.

    Example:
        2026-10-08
        ->
        raw/year=2026/month=10/day=08
    """

    run_day = pendulum.parse(run_date)

    return (
        f"{SOURCE_PREFIX}/"
        f"year={run_day.year}/"
        f"month={run_day.month:02d}/"
        f"day={run_day.day:02d}"
    )


def download_and_upload_source_files(run_date: str):
    """
    Download the latest OurAirports CSV files and upload them
    into the date-partitioned AirStats S3 landing zone.
    """

    s3 = boto3.client("s3")

    daily_prefix = build_daily_prefix(run_date)

    print(f"AirStats ingestion date: {run_date}")
    print(
        f"Target S3 prefix: "
        f"s3://{SOURCE_BUCKET}/{daily_prefix}/"
    )

    for filename in SOURCE_FILES:

        source_url = f"{OURAIRPORTS_BASE_URL}/{filename}"

        print(f"Downloading {filename}: {source_url}")

        request = urllib.request.Request(
            source_url,
            headers={
                "User-Agent": "airstats-mwaa/1.0"
            },
        )

        with urllib.request.urlopen(
            request,
            timeout=120,
        ) as response:
            data = response.read()

        if not data:
            raise ValueError(
                f"Downloaded file is empty: {filename}"
            )

        # Very basic CSV validation
        first_line = data.splitlines()[0]

        if b"," not in first_line:
            raise ValueError(
                f"{filename} does not appear to be valid CSV."
            )

        s3_key = f"{daily_prefix}/{filename}"

        s3.put_object(
            Bucket=SOURCE_BUCKET,
            Key=s3_key,
            Body=data,
            ContentType="text/csv",
            Metadata={
                "source": "ourairports",
                "ingestion-date": run_date,
            },
        )

        print(
            f"Uploaded {len(data):,} bytes -> "
            f"s3://{SOURCE_BUCKET}/{s3_key}"
        )


def check_source_files(run_date: str):
    """
    Validate that all required files exist in today's
    S3 partition and that none are empty.
    """

    s3 = boto3.client("s3")

    daily_prefix = build_daily_prefix(run_date)

    missing_files = []
    empty_files = []

    for filename in SOURCE_FILES:

        s3_key = f"{daily_prefix}/{filename}"

        try:
            response = s3.head_object(
                Bucket=SOURCE_BUCKET,
                Key=s3_key,
            )

        except ClientError as exc:

            error_code = exc.response["Error"]["Code"]

            if error_code in {
                "404",
                "NoSuchKey",
                "NotFound",
            }:
                missing_files.append(filename)
                continue

            raise

        if response["ContentLength"] <= 0:
            empty_files.append(filename)

    if missing_files:
        raise FileNotFoundError(
            f"Missing source files: {missing_files}"
        )

    if empty_files:
        raise ValueError(
            f"Empty source files: {empty_files}"
        )

    print(
        f"All {len(SOURCE_FILES)} expected files "
        f"are available under:"
    )

    print(
        f"s3://{SOURCE_BUCKET}/{daily_prefix}/"
    )


# ============================================================
# DAG
# ============================================================

with DAG(
    dag_id="airstats_pipeline",

    description=(
        "Daily OurAirports -> S3 -> Snowflake -> dbt pipeline"
    ),

    default_args=default_args,

    start_date=pendulum.datetime(
        2026,
        10,
        8,
        6,
        0,
        tz=BERLIN_TZ,
    ),

    # Run daily at 06:00 Germany time
    schedule="0 6 * * *",

    catchup=False,

    max_active_runs=1,

    dagrun_timeout=timedelta(hours=1),

    tags=[
        "airstats",
        "ourairports",
        "s3",
        "snowflake",
        "dbt",
        "ecs",
    ],

) as dag:


    # ========================================================
    # START
    # ========================================================

    start = EmptyOperator(
        task_id="start",
    )


    # ========================================================
    # REFRESH OURAIRPORTS SOURCE DATA
    # ========================================================

    refresh_source_files = PythonOperator(
        task_id="refresh_source_files",

        python_callable=download_and_upload_source_files,

        op_kwargs={
            "run_date": RUN_DATE_TEMPLATE,
        },

        execution_timeout=timedelta(minutes=15),
    )


    # ========================================================
    # VALIDATE S3 FILES
    # ========================================================

    check_s3_files = PythonOperator(
        task_id="check_source_files",

        python_callable=check_source_files,

        op_kwargs={
            "run_date": RUN_DATE_TEMPLATE,
        },

        execution_timeout=timedelta(minutes=5),
    )


    # ========================================================
    # TEST SNOWFLAKE CONNECTION
    # ========================================================

    test_snowflake_connection = SQLExecuteQueryOperator(
        task_id="test_snowflake_connection",

        conn_id="snowflake_airstats",

        sql="""
            SELECT
                CURRENT_USER(),
                CURRENT_ROLE(),
                CURRENT_WAREHOUSE(),
                CURRENT_DATABASE(),
                CURRENT_SCHEMA();
        """,

        execution_timeout=timedelta(minutes=5),
    )


    # ========================================================
    # LOAD DAILY SNAPSHOTS INTO SNOWFLAKE RAW
    # ========================================================

    load_tasks = []

    for task_name, config in LOAD_CONFIG.items():

        table_name = config["table"]
        filename = config["file"]

        load_task = SQLExecuteQueryOperator(
            task_id=f"load_{task_name}",

            conn_id="snowflake_airstats",

            sql=[
                "BEGIN",

                f"""
                DELETE FROM AIRSTATS_RAW.RAW.{table_name}
                """,

                f"""
                COPY INTO AIRSTATS_RAW.RAW.{table_name}
                FROM @AIRSTATS_RAW.RAW.OURAIRPORTS_STAGE/{DAILY_STAGE_PREFIX}/{filename}
                FILE_FORMAT = (
                    FORMAT_NAME = AIRSTATS_RAW.RAW.CSV_LOAD_FORMAT
                )
                FORCE = TRUE
                ON_ERROR = 'ABORT_STATEMENT'
                """,

                "COMMIT",
            ],

            autocommit=False,

            execution_timeout=timedelta(minutes=15),
        )

        load_tasks.append(load_task)


    # ========================================================
    # RUN DBT BUILD IN ECS / FARGATE
    # ========================================================

    run_dbt_fargate = EcsRunTaskOperator(
        task_id="run_dbt_fargate",

        cluster="airstats-dbt-cluster",

        task_definition="airstats-dbt-task:5",

        launch_type="FARGATE",

        overrides={
            "containerOverrides": [
                {
                    "name": "airstats-dbt",
                    "command": [
                        "dbt",
                        "build",
                    ],
                }
            ]
        },

        network_configuration={
            "awsvpcConfiguration": {
                "subnets": [
                    "subnet-05b1632afcabe15d2",
                ],
                "assignPublicIp": "ENABLED",
            }
        },

        awslogs_group="/ecs/airstats-dbt-task",

        awslogs_region="us-east-1",

        awslogs_stream_prefix="ecs",

        wait_for_completion=True,

        execution_timeout=timedelta(minutes=30),
    )


    # ========================================================
    # END
    # ========================================================

    end = EmptyOperator(
        task_id="end",
    )


    # ========================================================
    # DEPENDENCIES
    # ========================================================

    (
        start
        >> refresh_source_files
        >> check_s3_files
        >> test_snowflake_connection
    )

    test_snowflake_connection >> load_tasks

    load_tasks >> run_dbt_fargate >> end