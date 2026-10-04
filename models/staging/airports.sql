SELECT
    id                  AS airport_id,
    ident               AS airport_ident,
    type                AS airport_type,
    name                AS airport_name,
    latitude_deg,
    longitude_deg,
    elevation_ft,
    continent,
    iso_country         AS country_code,
    iso_region          AS region_code,
    municipality,
    scheduled_service,
    gps_code,
    icao_code,
    iata_code,
    local_code,
    home_link,
    wikipedia_link,
    keywords

FROM {{ source('airstats_raw', 'airports') }}