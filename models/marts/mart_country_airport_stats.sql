SELECT
   country_code,
   country_name,
   count(distinct airport_id) AS airport_count,
   sum(runway_count) AS total_runway_count,
   avg(runway_count) AS avg_runways_per_airport,
   MAX(runway_count) AS max_runways_at_single_airport
   from {{ ref('int_airport_runway_stats') }}
GROUP BY
   country_code,
   country_name
