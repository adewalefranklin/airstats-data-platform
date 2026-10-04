SELECT
    id                  AS region_id,
    code                AS region_code,
    local_code,
    name                AS region_name,
    continent,
    iso_country         AS country_code,
    wikipedia_link,
    keywords

FROM {{ source('airstats_raw', 'regions') }}