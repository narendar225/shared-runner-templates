#!/usr/bin/env bash
# Publish Document to Exchange Script
# Publishes markdown documentation pages to Anypoint Exchange asset.
# Creates new pages or updates existing ones based on *.md files in the current directory.
#
# Required env vars: GROUP_ID, ASSET_ID, ASSET_VERSION
# Optional env vars: WORKING_DIRECTORY (dir with *.md files, default: .)
set -euo pipefail

if [ -z "${GROUP_ID:-}" ] || [ -z "${ASSET_ID:-}" ] || [ -z "${ASSET_VERSION:-}" ]; then
  echo "Error: GROUP_ID, ASSET_ID, and ASSET_VERSION are required."
  exit 1
fi

ASSET_IDENTIFIER="$GROUP_ID/$ASSET_ID/$ASSET_VERSION"
echo "ASSET_IDENTIFIER: $ASSET_IDENTIFIER"

WORKING_DIRECTORY="${WORKING_DIRECTORY:-.}"
echo "Reading *.md files from: $WORKING_DIRECTORY"

RAW_OUTPUT=$(anypoint-cli-v4 exchange:asset:page:list "$ASSET_IDENTIFIER" --output json)
# Extract JSON - skip any CLI header line (sed '1d' breaks pretty-printed JSON)
CLEAN_JSON=$(echo "$RAW_OUTPUT" | sed -n '/^[[:space:]]*[\[{]/,$p')

echo "$CLEAN_JSON"

echo "Starting Sync for Asset: $ASSET_IDENTIFIER"

# --- Step 1: Upload all images and capture resource references from upload response ---
# Store mappings in temp file: filename|reference (portable, works with bash 3.x)
IMAGE_REF_FILE=$(mktemp)
trap 'rm -f "$IMAGE_REF_FILE"' EXIT

echo "Uploading images to Exchange Resources..."
if [ -d "$WORKING_DIRECTORY/images" ]; then
  for img in "$WORKING_DIRECTORY"/images/*; do
    if [ -f "$img" ]; then
      filename=$(basename "$img")
      echo "Uploading $filename..."
      echo "Running: anypoint-cli-v4 exchange:asset:resource:upload \
        "$ASSET_IDENTIFIER" \
        "$WORKING_DIRECTORY/images/$filename""
      UPLOAD_RESPONSE=$(anypoint-cli-v4 exchange:asset:resource:upload \
        "$ASSET_IDENTIFIER" \
        "$WORKING_DIRECTORY/images/$filename" 2>&1)
      # Extract markdown reference from CLI output. Expected format:
      #   Uploading resource...
      #   Resource uploaded. To use, add the following markdown code in the desired page:
      #   ![API-LED](resources/API-LED-5faee6cb-ff07-4b2b-ae32-b379f43ef452.png)
      # Clean the response of terminal colors before grepping
      #clean_response=$(echo "$UPLOAD_RESPONSE" | sed 's/\x1b\[[0-9;]*m//g')
      #ref_value=$(echo "$clean_response" | grep -oE '!\[[^\]]*\]\(resources/[^)]+\)' | head -1)
      ref_value=$(printf '%s' "$UPLOAD_RESPONSE" | grep -oE '!\[[^]]*\]\(resources/[^)]+\)' | head -1)
      if [ -n "$ref_value" ]; then
        printf '%s\t%s\n' "$filename" "$ref_value" >> "$IMAGE_REF_FILE"
        echo "  -> Mapped images/$filename to $ref_value"
      else
        echo "  -> Warning: Could not extract reference from upload response for $filename"
      fi
    fi
  done
fi

# --- Step 2: Process and Upload/Update Markdown files ---
echo "Processing Markdown files..."
# Use absolute path for temp_docs so CLI can find files (workflow may run from different cwd)
TEMP_DOCS_DIR="$(pwd)/temp_docs"
mkdir -p "$TEMP_DOCS_DIR"

for md_file in "$WORKING_DIRECTORY"/*.md; do
    if [ -f "$md_file" ]; then
        page_name=$(basename "$md_file" .md)
        display_name="$page_name"
        
        echo "Updating references in $md_file..."
        # Replace images/filename with reference from upload response
        # Handles <img src="images/API-LED.png" /> and ![alt](images/API-LED.png)
        MD_OUTPUT="$TEMP_DOCS_DIR/$page_name.md"
        cp "$md_file" "$MD_OUTPUT"
        if [ -s "$IMAGE_REF_FILE" ]; then
          while IFS=$'\t' read -r ref_filename ref_value; do
            [ -z "$ref_filename" ] || [ -z "$ref_value" ] && continue
            # Escape for sed pattern: . [ ] \ * ^ $
            ref_escaped_pattern=$(printf '%s' "$ref_filename" | sed 's/\\/\\\\/g; s/\[/\\[/g; s/\]/\\]/g; s/\./\\./g; s/\*/\\*/g; s/\^/\\^/g; s/\$/\\$/g')
            # Escape for sed replacement: \ and &
            ref_escaped_repl=$(printf '%s' "$ref_value" | sed 's/\\/\\\\/g; s/&/\\&/g')
            # Replace full <img ... src="images/filename" ... /> with markdown reference
            echo "Running: sed \"s|<img[^>]*src=\"images/$ref_escaped_pattern\"[^>]*>|$ref_escaped_repl|g\" \"$MD_OUTPUT\" > \"$MD_OUTPUT.new\""
            sed "s|<img[^>]*src=\"images/$ref_escaped_pattern\"[^>]*>|$ref_escaped_repl|g" "$MD_OUTPUT" > "$MD_OUTPUT.new"
            mv "$MD_OUTPUT.new" "$MD_OUTPUT"
            # Replace markdown ![alt](images/filename) with the reference
            echo "Running: sed \"s|!\[[^\]]*\](images/$ref_escaped_pattern)|$ref_escaped_repl|g\" \"$MD_OUTPUT\" > \"$MD_OUTPUT.new\""
            sed "s|!\[[^\]]*\](images/$ref_escaped_pattern)|$ref_escaped_repl|g" "$MD_OUTPUT" > "$MD_OUTPUT.new"
            mv "$MD_OUTPUT.new" "$MD_OUTPUT"
          done < "$IMAGE_REF_FILE"
        fi

  echo "--- Content of $MD_OUTPUT ---"
  cat "$MD_OUTPUT"
  echo "--- End of $MD_OUTPUT ---"

  echo "Processing page: $display_name for Asset: $ASSET_IDENTIFIER"
  if [ ! -f "$MD_OUTPUT" ]; then
    echo "Error: MD file not found at $MD_OUTPUT"
    exit 1
  fi
  EXISTS=$(echo "$CLEAN_JSON" | jq -r ".[] | select(.name == \"$display_name\") | .name" 2>/dev/null)
  if [ -n "$EXISTS" ]; then
    echo "Found '$display_name'. Running UPDATE..."
    anypoint-cli-v4 exchange:asset:page:update "$ASSET_IDENTIFIER" "$display_name" "$MD_OUTPUT"
  else
    echo "Not found. Running UPLOAD..."
    anypoint-cli-v4 exchange:asset:page:upload "$ASSET_IDENTIFIER" "$display_name" "$MD_OUTPUT"
  fi
    fi
done

rm -rf "$TEMP_DOCS_DIR"
echo "Sync Complete!"
