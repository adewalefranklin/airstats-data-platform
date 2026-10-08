FROM python:3.10-slim

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir dbt-snowflake==1.12.1

COPY dbt_project.yml .
COPY models ./models
COPY macros ./macros
COPY snapshots ./snapshots
COPY seeds ./seeds
COPY tests ./tests

RUN mkdir -p /root/.dbt
COPY docker/profiles.yml /root/.dbt/profiles.yml

CMD ["dbt", "--version"]