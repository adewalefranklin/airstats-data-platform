SELECT
    id               AS comment_id,
    thread_ref,
    airport_ref       AS airport_id,
    airport_ident,
    date              AS comment_date,
    member_nickname,
    subject           AS comment_subject,
    body              AS comment_body
FROM {{ source('airstats_raw', 'airport_comments') }}