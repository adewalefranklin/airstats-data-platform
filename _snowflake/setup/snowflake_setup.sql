/* =============================================================================
   AIRSTATS DATA PLATFORM
   Snowflake Infrastructure Setup

   Purpose
   -------
   Reproducible Snowflake setup for the AirStats data platform.

   Architecture
   ------------
   AIRSTATS_RAW   -> Raw data loaded from AWS S3
   AIRSTATS_DEV   -> Developer/dbt transformation environment
   AIRSTATS_CI    -> Isolated GitHub Actions validation environment
   AIRSTATS_PROD  -> Production dbt deployment environment

   Security model
   --------------
   Users receive roles.
   Roles receive privileges.
   Privileges are granted only on required Snowflake objects.

   IMPORTANT
   ---------
   - Do not commit passwords or private keys to Git.
   - Replace placeholder values before execution.
   - CREATE OR REPLACE statements may destroy existing objects/data.
============================================================================= */


/* =============================================================================
   1. COMPUTE WAREHOUSES
============================================================================= */

USE ROLE SYSADMIN;

-- Dedicated warehouse for loading raw files from S3 into Snowflake.
CREATE WAREHOUSE IF NOT EXISTS AIRSTATS_LOAD_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE;

-- Dedicated compute for dbt development, CI and production transformations.
CREATE WAREHOUSE IF NOT EXISTS AIRSTATS_DBT_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE;

-- Dedicated warehouse for BI/reporting workloads.
CREATE WAREHOUSE IF NOT EXISTS AIRSTATS_BI_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE;


/* =============================================================================
   2. DATABASES AND SCHEMAS
============================================================================= */

-- RAW layer: immutable/landing representation of OurAirports source data.
CREATE DATABASE IF NOT EXISTS AIRSTATS_RAW;
CREATE SCHEMA IF NOT EXISTS AIRSTATS_RAW.RAW;


-- DEV environment used by DBT_USER during development.
CREATE DATABASE IF NOT EXISTS AIRSTATS_DEV;

CREATE SCHEMA IF NOT EXISTS AIRSTATS_DEV.STAGING;
CREATE SCHEMA IF NOT EXISTS AIRSTATS_DEV.INTERMEDIATE;
CREATE SCHEMA IF NOT EXISTS AIRSTATS_DEV.MARTS;
CREATE SCHEMA IF NOT EXISTS AIRSTATS_DEV.SNAPSHOTS;


-- CI environment used exclusively by GitHub Actions pull-request validation.
CREATE DATABASE IF NOT EXISTS AIRSTATS_CI;

CREATE SCHEMA IF NOT EXISTS AIRSTATS_CI.STAGING;
CREATE SCHEMA IF NOT EXISTS AIRSTATS_CI.INTERMEDIATE;
CREATE SCHEMA IF NOT EXISTS AIRSTATS_CI.MARTS;
CREATE SCHEMA IF NOT EXISTS AIRSTATS_CI.SNAPSHOTS;


-- Production environment populated only after validated code is merged to main.
CREATE DATABASE IF NOT EXISTS AIRSTATS_PROD;

CREATE SCHEMA IF NOT EXISTS AIRSTATS_PROD.STAGING;
CREATE SCHEMA IF NOT EXISTS AIRSTATS_PROD.INTERMEDIATE;
CREATE SCHEMA IF NOT EXISTS AIRSTATS_PROD.MARTS;
CREATE SCHEMA IF NOT EXISTS AIRSTATS_PROD.SNAPSHOTS;


/* =============================================================================
   3. AWS STORAGE INTEGRATION
============================================================================= */

-- Storage integrations are account-level objects.
-- ACCOUNTADMIN is used here unless CREATE INTEGRATION has been delegated.
USE ROLE ACCOUNTADMIN;

CREATE STORAGE INTEGRATION IF NOT EXISTS S3_INT
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN =
        'arn:aws:iam::<AWS_ACCOUNT_ID>:role/AIRSTATS_SNOWFLAKE_ROLE'
    STORAGE_ALLOWED_LOCATIONS =
        ('s3://airstats-adewale/raw/');

-- Retrieve Snowflake-generated IAM principal and external ID.
-- These values are required when configuring the AWS IAM trust relationship.
DESC INTEGRATION S3_INT;


/* =============================================================================
   4. CSV FILE FORMATS
============================================================================= */

USE ROLE SYSADMIN;

-- Used for ordinary COPY INTO operations.
-- Header row is skipped because loads are positional.
CREATE OR REPLACE FILE FORMAT AIRSTATS_RAW.RAW.CSV_LOAD_FORMAT
    TYPE = CSV
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL');


-- Used when inspecting/inferencing CSV schemas.
-- PARSE_HEADER enables Snowflake to use source column names.
CREATE OR REPLACE FILE FORMAT AIRSTATS_RAW.RAW.CSV_INFER_FORMAT
    TYPE = CSV
    PARSE_HEADER = TRUE
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL');


/* =============================================================================
   5. EXTERNAL STAGE
============================================================================= */

CREATE OR REPLACE STAGE AIRSTATS_RAW.RAW.OURAIRPORTS_STAGE
    URL = 's3://airstats-adewale/raw/'
    STORAGE_INTEGRATION = S3_INT
    FILE_FORMAT = AIRSTATS_RAW.RAW.CSV_LOAD_FORMAT;


/* =============================================================================
   6. RBAC ROLES
============================================================================= */

USE ROLE SECURITYADMIN;

-- Loads source data from S3 into the RAW database.
CREATE ROLE IF NOT EXISTS INGESTOR_ROLE;

-- Runs dbt transformations during normal development.
CREATE ROLE IF NOT EXISTS DBT_ROLE;

-- Used exclusively by GitHub Actions for pull-request validation.
CREATE ROLE IF NOT EXISTS DBT_CI_ROLE;

-- Used exclusively by GitHub Actions for deployment to production.
CREATE ROLE IF NOT EXISTS DBT_PROD_ROLE;

-- Read-only role for BI / Power BI consumption of curated marts.
CREATE ROLE IF NOT EXISTS ANALYST_ROLE;


-- Attach custom roles beneath SYSADMIN so administrators can inherit them.
GRANT ROLE INGESTOR_ROLE TO ROLE SYSADMIN;
GRANT ROLE DBT_ROLE TO ROLE SYSADMIN;
GRANT ROLE DBT_CI_ROLE TO ROLE SYSADMIN;
GRANT ROLE DBT_PROD_ROLE TO ROLE SYSADMIN;
GRANT ROLE ANALYST_ROLE TO ROLE SYSADMIN;


/* =============================================================================
   7. INGESTOR ROLE PRIVILEGES

   Responsibility:
     AWS S3 -> Snowflake RAW

   May:
     - use load warehouse
     - access RAW database/schema
     - read stage
     - use file formats
     - create/load RAW tables

   Does not require access to DEV, CI or PROD.
============================================================================= */

USE ROLE SECURITYADMIN;

GRANT USAGE ON WAREHOUSE AIRSTATS_LOAD_WH
TO ROLE INGESTOR_ROLE;

GRANT USAGE ON DATABASE AIRSTATS_RAW
TO ROLE INGESTOR_ROLE;

GRANT USAGE ON SCHEMA AIRSTATS_RAW.RAW
TO ROLE INGESTOR_ROLE;

GRANT CREATE TABLE ON SCHEMA AIRSTATS_RAW.RAW
TO ROLE INGESTOR_ROLE;

GRANT USAGE ON FILE FORMAT AIRSTATS_RAW.RAW.CSV_LOAD_FORMAT
TO ROLE INGESTOR_ROLE;

GRANT USAGE ON FILE FORMAT AIRSTATS_RAW.RAW.CSV_INFER_FORMAT
TO ROLE INGESTOR_ROLE;

GRANT USAGE ON STAGE AIRSTATS_RAW.RAW.OURAIRPORTS_STAGE
TO ROLE INGESTOR_ROLE;

GRANT INSERT, SELECT
ON FUTURE TABLES IN SCHEMA AIRSTATS_RAW.RAW
TO ROLE INGESTOR_ROLE;


/* =============================================================================
   8. DEVELOPMENT DBT ROLE

   Responsibility:
     RAW -> DEV.STAGING -> DEV.INTERMEDIATE -> DEV.MARTS

   RAW is read-only.
   DBT_ROLE can create transformation objects only in DEV.
============================================================================= */

GRANT USAGE ON WAREHOUSE AIRSTATS_DBT_WH
TO ROLE DBT_ROLE;

-- RAW read access.
GRANT USAGE ON DATABASE AIRSTATS_RAW
TO ROLE DBT_ROLE;

GRANT USAGE ON SCHEMA AIRSTATS_RAW.RAW
TO ROLE DBT_ROLE;

GRANT SELECT ON ALL TABLES IN SCHEMA AIRSTATS_RAW.RAW
TO ROLE DBT_ROLE;

GRANT SELECT ON FUTURE TABLES IN SCHEMA AIRSTATS_RAW.RAW
TO ROLE DBT_ROLE;


-- DEV access.
GRANT USAGE ON DATABASE AIRSTATS_DEV
TO ROLE DBT_ROLE;

GRANT USAGE ON SCHEMA AIRSTATS_DEV.STAGING
TO ROLE DBT_ROLE;

GRANT USAGE ON SCHEMA AIRSTATS_DEV.INTERMEDIATE
TO ROLE DBT_ROLE;

GRANT USAGE ON SCHEMA AIRSTATS_DEV.MARTS
TO ROLE DBT_ROLE;

GRANT USAGE ON SCHEMA AIRSTATS_DEV.SNAPSHOTS
TO ROLE DBT_ROLE;


-- dbt needs creation privileges for its materializations.
GRANT CREATE TABLE, CREATE VIEW
ON SCHEMA AIRSTATS_DEV.STAGING
TO ROLE DBT_ROLE;

GRANT CREATE TABLE, CREATE VIEW
ON SCHEMA AIRSTATS_DEV.INTERMEDIATE
TO ROLE DBT_ROLE;

GRANT CREATE TABLE, CREATE VIEW
ON SCHEMA AIRSTATS_DEV.MARTS
TO ROLE DBT_ROLE;

GRANT CREATE TABLE
ON SCHEMA AIRSTATS_DEV.SNAPSHOTS
TO ROLE DBT_ROLE;


/* =============================================================================
   9. CI ROLE

   Responsibility:
     Validate pull requests in an environment isolated from DEV and PROD.

   GitHub Actions:
     DBT_CI_USER -> DBT_CI_ROLE -> AIRSTATS_CI

   RAW remains read-only.
============================================================================= */

GRANT USAGE ON WAREHOUSE AIRSTATS_DBT_WH
TO ROLE DBT_CI_ROLE;


-- RAW source access.
GRANT USAGE ON DATABASE AIRSTATS_RAW
TO ROLE DBT_CI_ROLE;

GRANT USAGE ON SCHEMA AIRSTATS_RAW.RAW
TO ROLE DBT_CI_ROLE;

GRANT SELECT ON ALL TABLES IN SCHEMA AIRSTATS_RAW.RAW
TO ROLE DBT_CI_ROLE;

GRANT SELECT ON FUTURE TABLES IN SCHEMA AIRSTATS_RAW.RAW
TO ROLE DBT_CI_ROLE;


-- Isolated CI environment.
GRANT USAGE ON DATABASE AIRSTATS_CI
TO ROLE DBT_CI_ROLE;

GRANT USAGE ON ALL SCHEMAS IN DATABASE AIRSTATS_CI
TO ROLE DBT_CI_ROLE;


GRANT CREATE TABLE, CREATE VIEW
ON SCHEMA AIRSTATS_CI.STAGING
TO ROLE DBT_CI_ROLE;

GRANT CREATE TABLE, CREATE VIEW
ON SCHEMA AIRSTATS_CI.INTERMEDIATE
TO ROLE DBT_CI_ROLE;

GRANT CREATE TABLE, CREATE VIEW
ON SCHEMA AIRSTATS_CI.MARTS
TO ROLE DBT_CI_ROLE;

GRANT CREATE TABLE, CREATE VIEW
ON SCHEMA AIRSTATS_CI.SNAPSHOTS
TO ROLE DBT_CI_ROLE;


GRANT SELECT ON ALL TABLES IN DATABASE AIRSTATS_CI
TO ROLE DBT_CI_ROLE;

GRANT SELECT ON FUTURE TABLES IN DATABASE AIRSTATS_CI
TO ROLE DBT_CI_ROLE;

GRANT SELECT ON ALL VIEWS IN DATABASE AIRSTATS_CI
TO ROLE DBT_CI_ROLE;

GRANT SELECT ON FUTURE VIEWS IN DATABASE AIRSTATS_CI
TO ROLE DBT_CI_ROLE;


/* =============================================================================
   10. PRODUCTION DEPLOYMENT ROLE

   Responsibility:
     Deploy validated dbt code to AIRSTATS_PROD after merge to main.

   GitHub Actions:
     DBT_PROD_USER -> DBT_PROD_ROLE -> AIRSTATS_PROD

   This role cannot build inside DEV or CI.
============================================================================= */

GRANT USAGE ON WAREHOUSE AIRSTATS_DBT_WH
TO ROLE DBT_PROD_ROLE;


-- RAW source access.
GRANT USAGE ON DATABASE AIRSTATS_RAW
TO ROLE DBT_PROD_ROLE;

GRANT USAGE ON SCHEMA AIRSTATS_RAW.RAW
TO ROLE DBT_PROD_ROLE;

GRANT SELECT ON ALL TABLES IN SCHEMA AIRSTATS_RAW.RAW
TO ROLE DBT_PROD_ROLE;

GRANT SELECT ON FUTURE TABLES IN SCHEMA AIRSTATS_RAW.RAW
TO ROLE DBT_PROD_ROLE;


-- Production environment.
GRANT USAGE ON DATABASE AIRSTATS_PROD
TO ROLE DBT_PROD_ROLE;

GRANT USAGE ON ALL SCHEMAS IN DATABASE AIRSTATS_PROD
TO ROLE DBT_PROD_ROLE;


GRANT CREATE TABLE, CREATE VIEW
ON SCHEMA AIRSTATS_PROD.STAGING
TO ROLE DBT_PROD_ROLE;

GRANT CREATE TABLE, CREATE VIEW
ON SCHEMA AIRSTATS_PROD.INTERMEDIATE
TO ROLE DBT_PROD_ROLE;

GRANT CREATE TABLE, CREATE VIEW
ON SCHEMA AIRSTATS_PROD.MARTS
TO ROLE DBT_PROD_ROLE;

GRANT CREATE TABLE, CREATE VIEW
ON SCHEMA AIRSTATS_PROD.SNAPSHOTS
TO ROLE DBT_PROD_ROLE;


/* =============================================================================
   11. ANALYST / BI ROLE

   Responsibility:
     Read curated MARTS through a dedicated BI warehouse.

   No permissions are granted on RAW or intermediate transformation layers.
============================================================================= */

GRANT USAGE ON WAREHOUSE AIRSTATS_BI_WH
TO ROLE ANALYST_ROLE;

GRANT USAGE ON DATABASE AIRSTATS_DEV
TO ROLE ANALYST_ROLE;

GRANT USAGE ON SCHEMA AIRSTATS_DEV.MARTS
TO ROLE ANALYST_ROLE;

GRANT SELECT ON ALL TABLES IN SCHEMA AIRSTATS_DEV.MARTS
TO ROLE ANALYST_ROLE;

GRANT SELECT ON FUTURE TABLES IN SCHEMA AIRSTATS_DEV.MARTS
TO ROLE ANALYST_ROLE;

GRANT SELECT ON ALL VIEWS IN SCHEMA AIRSTATS_DEV.MARTS
TO ROLE ANALYST_ROLE;

GRANT SELECT ON FUTURE VIEWS IN SCHEMA AIRSTATS_DEV.MARTS
TO ROLE ANALYST_ROLE;

GRANT USAGE ON DATABASE AIRSTATS_PROD TO ROLE ANALYST_ROLE;
GRANT USAGE ON SCHEMA AIRSTATS_PROD.MARTS TO ROLE ANALYST_ROLE;

GRANT SELECT ON ALL TABLES IN SCHEMA AIRSTATS_PROD.MARTS
TO ROLE ANALYST_ROLE;

GRANT SELECT ON FUTURE TABLES IN SCHEMA AIRSTATS_PROD.MARTS
TO ROLE ANALYST_ROLE;


/* =============================================================================
   12. USERS / SERVICE IDENTITIES
============================================================================= */

USE ROLE USERADMIN;


-- Raw ingestion identity.
CREATE USER IF NOT EXISTS INGESTOR_USER
    DEFAULT_ROLE = INGESTOR_ROLE
    DEFAULT_WAREHOUSE = AIRSTATS_LOAD_WH;


-- Development dbt identity.
CREATE USER IF NOT EXISTS DBT_USER
    DEFAULT_ROLE = DBT_ROLE
    DEFAULT_WAREHOUSE = AIRSTATS_DBT_WH;


-- BI / Power BI identity.
CREATE USER IF NOT EXISTS BI_ANALYST_USER
    DEFAULT_ROLE = ANALYST_ROLE
    DEFAULT_WAREHOUSE = AIRSTATS_BI_WH;


-- GitHub Actions CI service identity.
-- Password is stored as a GitHub Actions secret, never in this repository.
CREATE USER IF NOT EXISTS DBT_CI_USER
    PASSWORD = '<SET_SECURELY_OUTSIDE_GIT>'
    DEFAULT_ROLE = DBT_CI_ROLE
    DEFAULT_WAREHOUSE = AIRSTATS_DBT_WH
    MUST_CHANGE_PASSWORD = FALSE;


-- GitHub Actions production deployment identity.
CREATE USER IF NOT EXISTS DBT_PROD_USER
    PASSWORD = '<SET_SECURELY_OUTSIDE_GIT>'
    DEFAULT_ROLE = DBT_PROD_ROLE
    DEFAULT_WAREHOUSE = AIRSTATS_DBT_WH
    MUST_CHANGE_PASSWORD = FALSE;


/* =============================================================================
   13. ASSIGN ROLES TO USERS

   DEFAULT_ROLE only specifies which role is activated at login.
   The GRANT ROLE statement actually authorizes the user to use that role.
============================================================================= */

USE ROLE SECURITYADMIN;

GRANT ROLE INGESTOR_ROLE TO USER INGESTOR_USER;
GRANT ROLE DBT_ROLE TO USER DBT_USER;
GRANT ROLE ANALYST_ROLE TO USER BI_ANALYST_USER;
GRANT ROLE DBT_CI_ROLE TO USER DBT_CI_USER;
GRANT ROLE DBT_PROD_ROLE TO USER DBT_PROD_USER;


/* =============================================================================
   14. RAW SOURCE TABLES

   NOTE:
   CREATE OR REPLACE is intentionally used for project initialization.
   Do not execute this section against populated production RAW tables unless
   replacement is intended.
============================================================================= */

USE ROLE INGESTOR_ROLE;
USE WAREHOUSE AIRSTATS_LOAD_WH;


CREATE OR REPLACE TABLE AIRSTATS_RAW.RAW.AIRPORTS (
    id NUMBER(6,0),
    ident TEXT,
    type TEXT,
    name TEXT,
    latitude_deg NUMBER(20,18),
    longitude_deg NUMBER(21,18),
    elevation_ft NUMBER(5,0),
    continent TEXT,
    iso_country TEXT,
    iso_region TEXT,
    municipality TEXT,
    scheduled_service BOOLEAN,
    icao_code TEXT,
    iata_code TEXT,
    gps_code TEXT,
    local_code TEXT,
    home_link TEXT,
    wikipedia_link TEXT,
    keywords TEXT
);


CREATE OR REPLACE TABLE AIRSTATS_RAW.RAW.RUNWAYS (
    id NUMBER(6,0),
    airport_ref NUMBER(6,0),
    airport_ident TEXT,
    length_ft NUMBER(5,0),
    width_ft NUMBER(4,0),
    surface TEXT,
    lighted NUMBER(1,0),
    closed NUMBER(1,0),
    le_ident TEXT,
    le_latitude_deg NUMBER(19,17),
    le_longitude_deg NUMBER(21,18),
    le_elevation_ft NUMBER(5,0),
    le_heading_degT NUMBER(5,2),
    le_displaced_threshold_ft NUMBER(4,0),
    he_ident TEXT,
    he_latitude_deg NUMBER(20,18),
    he_longitude_deg NUMBER(23,20),
    he_elevation_ft NUMBER(5,0),
    he_heading_degT NUMBER(5,2),
    he_displaced_threshold_ft NUMBER(4,0)
);


CREATE OR REPLACE TABLE AIRSTATS_RAW.RAW.AIRPORT_FREQUENCIES (
    id NUMBER(6,0),
    airport_ref NUMBER(6,0),
    airport_ident TEXT,
    type TEXT,
    description TEXT,
    frequency_mhz NUMBER(7,3)
);


CREATE OR REPLACE TABLE AIRSTATS_RAW.RAW.AIRPORT_COMMENTS (
    id NUMBER(6,0),
    thread_ref NUMBER(5,0),
    airport_ref NUMBER(6,0),
    airport_ident TEXT,
    date TIMESTAMP_NTZ,
    member_nickname TEXT,
    subject TEXT,
    body TEXT
);


CREATE OR REPLACE TABLE AIRSTATS_RAW.RAW.COUNTRIES (
    id NUMBER(6,0),
    code TEXT,
    name TEXT,
    continent TEXT,
    wikipedia_link TEXT,
    keywords TEXT
);


CREATE OR REPLACE TABLE AIRSTATS_RAW.RAW.REGIONS (
    id NUMBER(6,0),
    code TEXT,
    local_code TEXT,
    name TEXT,
    continent TEXT,
    iso_country TEXT,
    wikipedia_link TEXT,
    keywords TEXT
);


CREATE OR REPLACE TABLE AIRSTATS_RAW.RAW.NAVAIDS (
    id NUMBER(6,0),
    filename TEXT,
    ident TEXT,
    name TEXT,
    type TEXT,
    frequency_khz NUMBER(6,0),
    latitude_deg NUMBER(20,18),
    longitude_deg NUMBER(21,18),
    elevation_ft NUMBER(5,0),
    iso_country TEXT,
    dme_frequency_khz NUMBER(6,0),
    dme_channel TEXT,
    dme_latitude_deg NUMBER(7,5),
    dme_longitude_deg NUMBER(9,6),
    dme_elevation_ft NUMBER(4,0),
    slaved_variation_deg NUMBER(6,3),
    magnetic_variation_deg NUMBER(6,3),
    usageType TEXT,
    power TEXT,
    associated_airport TEXT
);


/* =============================================================================
   15. VERIFY EXTERNAL STAGE
============================================================================= */

LIST @AIRSTATS_RAW.RAW.OURAIRPORTS_STAGE;


/* =============================================================================
   16. LOAD RAW TABLES FROM S3
============================================================================= */

COPY INTO AIRSTATS_RAW.RAW.AIRPORTS
FROM @AIRSTATS_RAW.RAW.OURAIRPORTS_STAGE/airports.csv
FILE_FORMAT = (
    FORMAT_NAME = AIRSTATS_RAW.RAW.CSV_LOAD_FORMAT
)
ON_ERROR = 'ABORT_STATEMENT';


COPY INTO AIRSTATS_RAW.RAW.RUNWAYS
FROM @AIRSTATS_RAW.RAW.OURAIRPORTS_STAGE/runways.csv
FILE_FORMAT = (
    FORMAT_NAME = AIRSTATS_RAW.RAW.CSV_LOAD_FORMAT
)
ON_ERROR = 'ABORT_STATEMENT';


COPY INTO AIRSTATS_RAW.RAW.AIRPORT_FREQUENCIES
FROM @AIRSTATS_RAW.RAW.OURAIRPORTS_STAGE/airport-frequencies.csv
FILE_FORMAT = (
    FORMAT_NAME = AIRSTATS_RAW.RAW.CSV_LOAD_FORMAT
)
ON_ERROR = 'ABORT_STATEMENT';


COPY INTO AIRSTATS_RAW.RAW.AIRPORT_COMMENTS
FROM @AIRSTATS_RAW.RAW.OURAIRPORTS_STAGE/airport-comments.csv
FILE_FORMAT = (
    FORMAT_NAME = AIRSTATS_RAW.RAW.CSV_LOAD_FORMAT
)
ON_ERROR = 'ABORT_STATEMENT';


COPY INTO AIRSTATS_RAW.RAW.COUNTRIES
FROM @AIRSTATS_RAW.RAW.OURAIRPORTS_STAGE/countries.csv
FILE_FORMAT = (
    FORMAT_NAME = AIRSTATS_RAW.RAW.CSV_LOAD_FORMAT
)
ON_ERROR = 'ABORT_STATEMENT';


COPY INTO AIRSTATS_RAW.RAW.REGIONS
FROM @AIRSTATS_RAW.RAW.OURAIRPORTS_STAGE/regions.csv
FILE_FORMAT = (
    FORMAT_NAME = AIRSTATS_RAW.RAW.CSV_LOAD_FORMAT
)
ON_ERROR = 'ABORT_STATEMENT';


COPY INTO AIRSTATS_RAW.RAW.NAVAIDS
FROM @AIRSTATS_RAW.RAW.OURAIRPORTS_STAGE/navaids.csv
FILE_FORMAT = (
    FORMAT_NAME = AIRSTATS_RAW.RAW.CSV_LOAD_FORMAT
)
ON_ERROR = 'ABORT_STATEMENT';


/* =============================================================================
   17. VALIDATION / TROUBLESHOOTING QUERIES
============================================================================= */

-- Confirm active security/compute context.
SELECT
    CURRENT_USER(),
    CURRENT_ROLE(),
    CURRENT_WAREHOUSE();


-- Verify loaded airport row count.
SELECT COUNT(*)
FROM AIRSTATS_RAW.RAW.AIRPORTS;


-- Example source-data inspection.
SELECT *
FROM AIRSTATS_RAW.RAW.AIRPORTS
WHERE ISO_COUNTRY <> 'US'
LIMIT 10;


-- Inspect inferred schema using the header-aware file format.
SELECT *
FROM TABLE(
    INFER_SCHEMA(
        LOCATION =>
            '@AIRSTATS_RAW.RAW.OURAIRPORTS_STAGE/navaids.csv',
        FILE_FORMAT =>
            'AIRSTATS_RAW.RAW.CSV_INFER_FORMAT'
    )
);


-- Inspect Snowflake grants.
SHOW GRANTS TO ROLE INGESTOR_ROLE;
SHOW GRANTS TO ROLE DBT_ROLE;
SHOW GRANTS TO ROLE DBT_CI_ROLE;
SHOW GRANTS TO ROLE DBT_PROD_ROLE;
SHOW GRANTS TO ROLE ANALYST_ROLE;


SHOW GRANTS TO USER INGESTOR_USER;
SHOW GRANTS TO USER DBT_USER;
SHOW GRANTS TO USER DBT_CI_USER;
SHOW GRANTS TO USER DBT_PROD_USER;
SHOW GRANTS TO USER BI_ANALYST_USER;


-- Confirm CI deployment objects.
SHOW TABLES IN DATABASE AIRSTATS_CI;
SHOW VIEWS IN DATABASE AIRSTATS_CI;


-- Confirm production deployment objects.
SHOW TABLES IN DATABASE AIRSTATS_PROD;
SHOW VIEWS IN DATABASE AIRSTATS_PROD;