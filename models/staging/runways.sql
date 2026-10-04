SELECT
    id                          AS runway_id,
    airport_ref                 AS airport_id,
    airport_ident,
    length_ft,
    width_ft,
    surface,
    lighted,
    closed,
    le_ident,
    le_latitude_deg,
    le_longitude_deg,
    le_elevation_ft,
    le_heading_degt,
    le_displaced_threshold_ft,
    he_ident,
    he_latitude_deg,
    he_longitude_deg,
    he_elevation_ft,
    he_heading_degt,
    he_displaced_threshold_ft

FROM {{ source('airstats_raw', 'runways') }}