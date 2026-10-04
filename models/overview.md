{% docs __overview__ %}

# AirStats Pipeline

Welcome to the **AirStats data pipeline documentation**.

AirStats is an end-to-end aviation analytics pipeline built using
**AWS S3, Snowflake, dbt, and CI/CD**, with data sourced from OurAirports.

## Pipeline Lineage

The lineage graph below shows the flow from raw aviation data through
staging, intermediate transformations, and analytics-ready marts.

![Lineage Overview](_screenshots/lineage_graph.png)

## Pipeline Architecture

OurAirports
    ↓
AWS S3
    ↓
Snowflake RAW
    ↓
dbt STAGING
    ↓
INTERMEDIATE
    ↓
MARTS
    ↓
Power BI

{% enddocs %}
