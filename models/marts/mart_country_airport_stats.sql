SELECT
    country_code,
    country_name,
    COUNT(DISTINCT airport_id) AS airport_count,
    SUM(runway_count) AS total_runway_count,
    AVG(runway_count) AS avg_runways_per_airport,
    MAX(runway_count) AS max_runways_at_single_airport
FROM {{ ref('int_airport_runway_stats') }}
GROUP BY
    country_code,
    country_name