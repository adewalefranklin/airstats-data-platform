SELECT
    id                          AS navaid_id,
    filename,
    ident                       AS navaid_ident,
    name                        AS navaid_name,
    type                        AS navaid_type,
    frequency_khz,
    latitude_deg,
    longitude_deg,
    elevation_ft,
    iso_country                 AS country_code,
    dme_frequency_khz,
    dme_channel,
    dme_latitude_deg,
    dme_longitude_deg,
    dme_elevation_ft,
    slaved_variation_deg,
    magnetic_variation_deg,
    usagetype                   AS usage_type,
    power,
    associated_airport          AS associated_airport_ident

FROM {{ source('airstats_raw', 'navaids') }}
