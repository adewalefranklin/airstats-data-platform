SELECT
    a.airport_id,
    a.airport_ident,
    a.airport_name,
    a.country_code,
    c.country_name,
    COUNT(r.runway_id) AS runway_count --total number of runways for each airport
FROM {{ ref('airports') }} a

LEFT JOIN {{ ref('countries') }} c
    ON a.country_code = c.country_code

LEFT JOIN {{ ref('runways') }} r
    ON a.airport_id = r.airport_id

GROUP BY
    a.airport_id,
    a.airport_ident,
    a.airport_name,
    a.country_code,
    c.country_name