/*
 This query template performs the point-in-time correctness join for a single feature set table
 to the provided entity table.

 Copied from the existing template, modified for Spark SQL

 1. Concatenate the timestamp and entities from the feature set table with the entity dataset.
 Feature values are joined to this table later for improved efficiency.
 featureset_timestamp is equal to null in rows from the entity dataset.
 */
WITH union_features AS (
SELECT
  -- uuid is a unique identifier for each row in the entity dataset.
  uuid,
  -- event_timestamp contains the timestamps to join onto
  event_timestamp,
  -- the feature_timestamp, i.e. the latest occurrence of the requested feature relative to the entity_dataset timestamp
  NULL as {{ featureSet.project }}_{{ featureSet.name }}_feature_timestamp,
  -- created timestamp of the feature at the corresponding feature_timestamp
  NULL as created_timestamp,
  -- select only entities belonging to this feature set
  {{ featureSet.entities | join(', ')}},
  -- boolean for filtering the dataset later
  true AS is_entity_table
FROM `{{leftTableName}}`
UNION ALL
SELECT
  NULL as uuid,
  event_timestamp,
  event_timestamp as {{ featureSet.project }}_{{ featureSet.name }}_feature_timestamp,
  created_timestamp,
  {{ featureSet.entities | join(', ')}},
  false AS is_entity_table
FROM `tbl__{{featureSet.project}}_{{featureSet.name}}` WHERE event_timestamp <= '{{maxTimestamp}}'
{% if featureSet.maxAge == 0 %}{% else %}AND event_timestamp >= (CAST('{{ minTimestamp }}' as timestamp) - interval {{ featureSet.maxAge }} second){% endif %}
),
/*
 2. Window the data in the unioned dataset, partitioning by entity and ordering by event_timestamp, as
 well as is_entity_table.
 Within each window, back-fill the feature_timestamp - as a result of this, the null feature_timestamps
 in the rows from the entity table should now contain the latest timestamps relative to the row's
 event_timestamp.

 For rows where event_timestamp(provided datetime) - feature_timestamp > max age, set the
 feature_timestamp to null.
 */
joined AS (
SELECT
  uuid,
  event_timestamp,
  {{ featureSet.entities | join(', ')}},
  {% for feature in featureSet.features %}
  IF(event_timestamp >= {{ featureSet.project }}_{{ featureSet.name }}_feature_timestamp {% if featureSet.maxAge == 0 %}{% else %}AND (event_timestamp - interval {{ featureSet.maxAge }} second) < {{ featureSet.project }}_{{ featureSet.name }}_feature_timestamp{% endif %}, {{ featureSet.project }}__{{ featureSet.name }}__{{ feature.name }}, NULL) as {{ featureSet.project }}__{{ featureSet.name }}__{{ feature.name }}{% if loop.last %}{% else %}, {% endif %}
  {% endfor %}
FROM (
SELECT
  uuid,
  event_timestamp,
  {{ featureSet.entities | join(', ')}},
  FIRST_VALUE(created_timestamp, /* isIgnoreNull= */ true) over w AS created_timestamp,
  FIRST_VALUE({{ featureSet.project }}_{{ featureSet.name }}_feature_timestamp, /* isIgnoreNull= */ true) over w AS {{ featureSet.project }}_{{ featureSet.name }}_feature_timestamp,
  is_entity_table
FROM union_features
WINDOW w AS (PARTITION BY {{ featureSet.entities | join(', ') }} ORDER BY event_timestamp DESC, is_entity_table DESC, created_timestamp DESC ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
)
/*
 3. Select only the rows from the entity table, and join the features from the original feature set table
 to the dataset using the entity values, feature_timestamp, and created_timestamps.
 */
LEFT JOIN (
SELECT
  event_timestamp as {{ featureSet.project }}_{{ featureSet.name }}_feature_timestamp,
  created_timestamp,
  {{ featureSet.entities | join(', ')}},
  {% for feature in featureSet.features %}
  {{ feature.name }} as {{ featureSet.project }}__{{ featureSet.name }}__{{ feature.name }}{% if loop.last %}{% else %}, {% endif %}
  {% endfor %}
FROM `tbl__{{featureSet.project}}_{{featureSet.name}}` WHERE event_timestamp <= '{{maxTimestamp}}'
{% if featureSet.maxAge == 0 %}{% else %}AND event_timestamp >= (CAST('{{ minTimestamp }}' as timestamp) - interval {{ featureSet.maxAge }} second){% endif %}
) USING ({{ featureSet.project }}_{{ featureSet.name }}_feature_timestamp, created_timestamp, {{ featureSet.entities | join(', ')}})
WHERE is_entity_table
)
/*
 4. Finally, deduplicate the rows by selecting the first occurrence of each entity table row UUID.
 */
SELECT
  k.*
FROM (
    SELECT *, row_number() OVER (PARTITION by uuid ORDER BY event_timestamp DESC) AS rn FROM joined
) AS k WHERE rn == 1
