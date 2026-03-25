#!/usr/bin/env bash

# This script audits all Avro schemas in a Confluent Cloud Schema Registry for compatibility with
# the stricter Avro 1.12 validation that will be enabled in Confluent Cloud Schema Registry
# at the end of March 2026. Avro 1.12 introduces enforcement of:
#   - Valid Avro namespaces (names must start with [A-Za-z_], contain only [A-Za-z0-9_],
#     and namespaces must be dot-separated sequences of such names), and
#   - Correct field default values, where the JSON type of each default must match the
#     field’s Avro type (for unions, the default must be valid for at least one branch,
#     per the Avro 1.12 spec).
#
# The script connects to a Schema Registry instance (SR_URL, SR_API_KEY, SR_API_SECRET),
# iterates over all subjects and all of their versions, parses each Avro schema, and
# reports any versions that would be rejected once validation is enabled:
#   - bad_namespace  – namespace violates Avro 1.12 naming rules
#   - bad_default    – field default JSON type is incompatible with its declared type
#   - schema_parse_error – schema payload cannot be parsed as valid JSON Avro by the script and requires manual review.
#
# Use this tool to proactively identify and clean up problematic schemas before Avro 1.12
# validation is turned on, so that future schema registrations and evolutions do not start failing unexpectedly.
# 
# Run it with:
# SR_URL=... SR_API_KEY=... SR_API_SECRET=... ./check-avro-namespaces-and-defaults.sh [-v]
# and inspect the printed list of offending subject versions for remediation.

set -uo pipefail

# ---- CONFIGURE THESE ----
SR_URL="${SR_URL:-https://your-schema-registry-endpoint}"
SR_API_KEY="${SR_API_KEY:-}"
SR_API_SECRET="${SR_API_SECRET:-}"
# -------------------------

# ---- FLAGS ----
VERBOSE=0
if [[ "${1-}" == "-v" || "${1-}" == "--verbose" ]]; then
  VERBOSE=1
  shift
fi

info() {
  echo "INFO: $@" >&2
}

vlog() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "DEBUG: $@" >&2
  fi
}

AUTH_ARGS=()
if [[ -n "$SR_API_KEY" && -n "$SR_API_SECRET" ]]; then
  AUTH_ARGS=(-u "$SR_API_KEY:$SR_API_SECRET")
fi

vlog "Using Schema Registry URL: $SR_URL"

# ---------- Helper: fetch URL and split body/status ----------
fetch() {
  local url="$1"
  local resp
  if ! resp=$(curl -sS -w '\n%{http_code}' "${AUTH_ARGS[@]}" "$url" 2>&1); then
    echo "CURL_ERROR"
    echo "$resp"
    return 0
  fi

  local status body
  status=$(printf '%s\n' "$resp" | tail -n1)
  body=$(printf '%s\n' "$resp" | sed '$d')
  echo "$status"
  echo "$body"
}

# ---------- 1) List subjects ----------
subjects_resp=$(fetch "$SR_URL/subjects")
subjects_status=$(printf '%s\n' "$subjects_resp" | head -n1)
subjects_body=$(printf '%s\n' "$subjects_resp" | sed '1d')

if [[ "$subjects_status" == "CURL_ERROR" ]]; then
  echo "ERROR: Failed to reach Schema Registry at $SR_URL" >&2
  echo "Detail: $subjects_body" >&2
  exit 1
fi

if [[ "$subjects_status" == "401" ]]; then
  echo "ERROR: 401 Unauthorized when listing subjects from Schema Registry." >&2
  echo "Check SR_URL/SR_API_KEY/SR_API_SECRET (or API key/secret) and try again." >&2
  exit 1
fi

if [[ "$subjects_status" != "200" ]]; then
  echo "ERROR: HTTP $subjects_status when listing subjects from Schema Registry." >&2
  echo "Response body:" >&2
  echo "$subjects_body" >&2
  exit 1
fi

if ! printf '%s\n' "$subjects_body" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: /subjects returned non-JSON body:" >&2
  echo "$subjects_body" >&2
  exit 1
fi

total_subjects=$(printf '%s\n' "$subjects_body" | jq 'length')
info "Found $total_subjects subjects from Schema Registry"

# Materialize subjects into an array
subjects=()
while IFS= read -r subject; do
  subjects+=("$subject")
done <<< "$(printf '%s\n' "$subjects_body" | jq -r '.[]')"

checked_avro_versions=0
violating_versions=0
subjects_seen=0
violating_list=()

info "Iterating through all subjects and all versions to check Avro namespaces and defaults"

# ---------- 2) Iterate subjects and all their versions ----------
for subject in "${subjects[@]}"; do
  ((subjects_seen++))

  # Progress every 50 subjects
  if (( subjects_seen % 50 == 0 )); then
    info "Progress: checked $subjects_seen / $total_subjects subjects, $violating_versions invalid versions so far"
  fi

  # List all versions for the subject
  versions_resp=$(fetch "$SR_URL/subjects/${subject}/versions")
  versions_status=$(printf '%s\n' "$versions_resp" | head -n1)
  versions_body=$(printf '%s\n' "$versions_resp" | sed '1d')

  if [[ "$versions_status" == "CURL_ERROR" ]]; then
    vlog "curl failed when listing versions for subject '$subject'."
    vlog "Detail: $versions_body"
    continue
  fi

  if [[ "$versions_status" == "401" ]]; then
    echo "ERROR: 401 Unauthorized when listing versions for subject '$subject'." >&2
    echo "Check SR_URL/SR_API_KEY/SR_API_SECRET (or API key/secret) and try again." >&2
    exit 1
  fi

  if [[ "$versions_status" != "200" ]]; then
    vlog "HTTP $versions_status for subject '$subject' when calling /versions."
    vlog "Response body:"
    vlog "$versions_body"
    continue
  fi

  if ! printf '%s\n' "$versions_body" | jq -e . >/dev/null 2>&1; then
    vlog "Skipping subject '$subject' (non-JSON versions list from SR)."
    vlog "Body:"
    vlog "$versions_body"
    continue
  fi

  versions=()
  while IFS= read -r ver; do
    versions+=("$ver")
  done <<< "$(printf '%s\n' "$versions_body" | jq -r '.[]')"

  # Iterate all versions for this subject
  for version in "${versions[@]}"; do
    meta_resp=$(fetch "$SR_URL/subjects/${subject}/versions/${version}")
    meta_status=$(printf '%s\n' "$meta_resp" | head -n1)
    meta_body=$(printf '%s\n' "$meta_resp" | sed '1d')

    if [[ "$meta_status" == "CURL_ERROR" ]]; then
      vlog "curl failed when fetching version '$version' for subject '$subject'."
      vlog "Detail: $meta_body"
      continue
    fi

    if [[ "$meta_status" == "401" ]]; then
      echo "ERROR: 401 Unauthorized when fetching version '$version' for subject '$subject'." >&2
      echo "Check SR_URL/SR_API_KEY/SR_API_SECRET (or API key/secret) and try again." >&2
      exit 1
    fi

    if [[ "$meta_status" != "200" ]]; then
      vlog "HTTP $meta_status for subject '$subject' version '$version' when calling /versions/{version}."
      vlog "Response body:"
      vlog "$meta_body"
      continue
    fi

    if ! printf '%s\n' "$meta_body" | jq -e . >/dev/null 2>&1; then
      vlog "Skipping subject '$subject' version '$version' (non-JSON metadata from SR)."
      vlog "Body:"
      vlog "$meta_body"
      continue
    fi

    schema_type=$(printf '%s\n' "$meta_body" | jq -r '.schemaType // "AVRO"')
    if [[ "$schema_type" != "AVRO" ]]; then
      continue
    fi

    ((checked_avro_versions++))

    # Parse embedded schema JSON directly from meta_body
    schema_json=$(printf '%s\n' "$meta_body" | jq -c '.schema | fromjson?' 2>/dev/null)

    if [[ -z "$schema_json" || "$schema_json" == "null" ]]; then
      ((violating_versions++))
      reason="schema_parse_error"
      summary="$subject | version=$version | reason=$reason"
      violating_list+=("$summary")
      echo "$summary"
      vlog "Schema parse error for subject '$subject' version '$version'; treating as invalid"
      continue
    fi

    report=$(jq -r '
      def is_bad_ns:
        (split(".")
         | map(
             (test("^[A-Za-z_][A-Za-z0-9_]*$") | not)
             or . == "null"
             or . == "boolean"
             or . == "int"
             or . == "long"
             or . == "float"
             or . == "double"
             or . == "bytes"
             or . == "string"
           )
         | any);

      # Check whether a default value is compatible with a given Avro schema node.
      def is_default_ok_for_schema($schema; $d):
        if ($schema | type) == "string" then
          # Primitive or named type
          if   $schema == "null"    then ($d | type) == "null"
          elif $schema == "boolean" then ($d | type) == "boolean"
          elif ($schema == "int" or $schema == "long") then
            ($d | type) == "number" and ($d | floor) == $d
          elif ($schema == "float" or $schema == "double") then
            ($d | type) == "number"
          elif $schema == "string"  then ($d | type) == "string"
          elif $schema == "bytes"   then ($d | type) == "string"
          else
            # Named record/enum/fixed (referenced by name) – skip strict checking
            true
          end

        elif ($schema | type) == "object" then
          # Inline complex types
          if   $schema.type == "array"  then ($d | type) == "array"
          elif $schema.type == "map"    then ($d | type) == "object"
          elif $schema.type == "record" then ($d | type) == "object"
          elif $schema.type == "fixed"  then ($d | type) == "string"
          elif $schema.type == "enum"   then ($d | type) == "string"
          else
            true
          end

        elif ($schema | type) == "array" then
          # Union: default must match at least one branch (Avro 1.12)
          any($schema[]; is_default_ok_for_schema(.; $d))

        else
          # Fallback: don’t flag
          true
        end;

      def bad_defaults:
        ..
        | objects
        | select(has("fields"))
        | .fields[]
        | select(has("default"))
        | {name, ftype: .type, fdefault: .default}
        | select( is_default_ok_for_schema(.ftype; .fdefault) | not );

      {
        bad_namespaces: [ .. | objects | .namespace? // empty | select(is_bad_ns) ] | unique,
        bad_defaults:   [ bad_defaults ]
      }
    ' <<<"$schema_json")

    ns_count=$(jq '.bad_namespaces | length' <<<"$report")
    def_count=$(jq '.bad_defaults | length' <<<"$report")

    if (( ns_count > 0 || def_count > 0 )); then
      ((violating_versions++))

      reason=""
      if (( ns_count > 0 )); then
        reason="bad_namespace"
      fi
      if (( def_count > 0 )); then
        if [[ -n "$reason" ]]; then
          reason+=",bad_default"
        else
          reason="bad_default"
        fi
      fi

      # Collect names of fields with bad defaults (may be multiple)
      bad_default_fields=""
      if (( def_count > 0 )); then
        bad_default_fields=$(jq -r '.bad_defaults[].name' <<<"$report" 2>/dev/null | sort -u | paste -sd',' -)
      fi

      summary="subject=$subject | version=$version | reason=$reason"
      if (( def_count > 0 )) && [[ -n "$bad_default_fields" ]]; then
        summary+=" | bad_default_fields=$bad_default_fields"
      fi

      violating_list+=("$summary")

      # Immediately output subject name, version, reason, and fields (STDOUT)
      echo "$summary"

      # If verbose, also show details
      if [[ "$VERBOSE" -eq 1 ]]; then
        if (( ns_count > 0 )); then
          echo " Namespaces violating Avro naming rules:"
          jq -r '.bad_namespaces[] | " - (. )"' <<<"$report"
        fi

        if (( def_count > 0 )); then
          echo " Fields with potentially invalid Avro default values (heuristic):"
          jq -r '.bad_defaults[] |
            " - field: (.name) | type: (.ftype|@json) | default: (.fdefault|@json)"' \
            <<<"$report"
        fi

        echo
      fi
    fi
  done
done

info "Checked $checked_avro_versions Avro schema versions"
info "$violating_versions schema versions have potential namespace/default issues"

if (( violating_versions > 0 )); then
  info "Full list of violating subject versions (with reasons):"
  for entry in "${violating_list[@]}"; do
    echo "INFO: $entry" >&2
  done
else
  info "No violating schema versions found"
fi