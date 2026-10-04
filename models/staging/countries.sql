SELECT
    id                  AS country_id,
    code                AS country_code,
    name                AS country_name,
    continent,
    wikipedia_link,
    keywords

FROM {{ source('airstats_raw', 'countries') }}