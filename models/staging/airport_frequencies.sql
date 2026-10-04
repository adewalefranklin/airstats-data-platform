SELECT
    id                  AS frequency_id,
    airport_ref         AS airport_id,
    airport_ident,
    type                AS frequency_type,
    description         AS frequency_description,
    frequency_mhz

FROM {{ source('airstats_raw', 'airport_frequencies') }}