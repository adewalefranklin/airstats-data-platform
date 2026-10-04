{{ config(
    materialized='incremental',
    unique_key='comment_id'
) }}

select
    comment_id,
    thread_ref,
    airport_id,
    airport_ident,
    comment_date,
    member_nickname,
    comment_subject,
    comment_body
from {{ ref('airport_comments') }}

{% if is_incremental() %}
where comment_date > (
    select max(comment_date)
    from {{ this }}
)
{% endif %}