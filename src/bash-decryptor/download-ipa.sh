#!/bin/bash

# Load env_loader.sh
source "src/bash-decryptor/lib/env_loader.sh"

# Import app_utils.sh
source "src/bash-decryptor/lib/app_utils.sh"

install_app() {
  local bundleId=$1
  local absolute_path=$2

  if [[ -z "$bundleId" ]] || [[ -z "$absolute_path" ]]; then
    echo "❌ Missing bundle ID or absolute path."
    return 1
  fi

  # Only install if the app is not already installed
  if ! ideviceinstaller -l | grep -q "$bundleId"; then
    echo "⬇️ Installing app to the phone..."
    start_time=$(date +%s)
    installResponse=$(ideviceinstaller -w -i "$absolute_path" 2>&1)
    end_time=$(date +%s)
    elapsed_time=$((end_time - start_time))

    # ideviceinstaller has this string in the output
    if [[ "$installResponse" != *"Install: Complete"* ]]; then
      return 1
    fi

    echo "✅ Validated. App installed in $elapsed_time seconds."
  else
    echo "✅ Validated. App is already installed on the phone."
  fi

  return 0
}

decrypt_app() {
  local bundleId=$1
  local absolute_path=$2
  local decrypt_output

  decrypt_output=$(yarn bagbak "$bundleId" -o "ipa-files/decrypted/")

  if [[ "$decrypt_output" == *"Saved to"* ]]; then
    return 0
  fi

  echo "$decrypt_output"
  return 1
}

transfer_file() {
  local file_path="$1"
  local chatId="$2"
  local topicId="$3"
  local appInfoResponse="$4"

  local filename
  local updatedJson

  echo "ℹ️ Adding entry to MongoDB..."

  # Extract the file name from the file path
  filename=$(basename "$file_path")

  # Append the filename, chatId, topicId, and expiration date to the appInfoResponse JSON object
  updatedJson=$(echo "$appInfoResponse" | jq --arg filename "$filename" --arg chatId "$chatId" --arg topicId "$topicId" '. + {filename: $filename, chatId: $chatId, topicId: $topicId, expireAt: (now | strflocaltime("%Y-%m-%dT%H:%M:%SZ") | fromdate + 172800 | strftime("%Y-%m-%dT%H:%M:%SZ")) }')

  # Insert the updated JSON into the MongoDB collection
  mongosh "$MONGODB_URL" --quiet --eval "db.app_info_collection.insertOne($updatedJson)" &>/dev/null

  # Create a TTL index on the 'expireAt' field if it doesn't exist
  mongosh "$MONGODB_URL" --quiet --eval 'if (!db.app_info_collection.getIndexes().some(index => index.key.expireAt)) { db.app_info_collection.createIndex( { "expireAt": 1 }, { expireAfterSeconds: 0 } ) }' &>/dev/null
}

check_files() {
  local dir="$1"
  local pattern="$2"
  local file

  file=$(find "$dir" -type f -name "*$pattern*" -print -quit)
  if [[ -n "$file" ]]; then
    echo "$file"
    exit 1
  else
    exit 0
  fi
}

function uninstall_app() {
  local bundleId=$1

  if ideviceinstaller -l | grep -q "$bundleId"; then
    uninstallResponse=$(ideviceinstaller -U "$bundleId")
    if [[ "$uninstallResponse" != *"Uninstall: Complete"* ]]; then
      echo "❌ Could not uninstall app."
      return 1
    fi

    return 0
  fi

  echo "❌ Could not uninstall app."
  return 1
}

main() {
  local trackId="$1"
  local countryCode="$2"
  local chatId="$3"
  local topicId="$4"
  local appInfoResponse=""

  local bundleId
  local fileSizeBytes
  local price
  local decryptedIPA
  local downloadedIPA
  local downloadResponse
  local loginResponse

  echo "🔍 Looking up app in the $(echo "$countryCode" | tr '[:lower:]' '[:upper:]') region..."

  # Quit if trackId is not a number
  if ! [[ "$trackId" =~ ^[0-9]+$ ]]; then
    echo "❌ Invalid track ID."
    exit 1
  fi

  appInfoResponse=$(get_app_info_by_id "$trackId" "$countryCode")
  if [[ $? -eq 1 ]]; then
    echo "❌ Failed to lookup $trackId."
    exit 1
  fi

  bundleId=$(echo "$appInfoResponse" | jq -r '.bundleId')
  fileSizeBytes=$(echo "$appInfoResponse" | jq -r '.fileSizeBytes')
  version=$(echo "$appInfoResponse" | jq -r '.version')

  echo "🔍 Bundle ID: $bundleId"

  price=$(echo "$appInfoResponse" | jq -r '.price')

  if [ $(echo "$price != 0" | bc -l) -eq 1 ]; then
    echo "ℹ️ Checking license..."
    hasLicense=$(timeout 3 "$ipatool" --keychain-passphrase "$SSH_PASSWORD" --non-interactive download -b "$bundleId" 2>&1)

    if [[ "$hasLicense" = *"license is required"* ]]; then
      echo "❌ License is required for this paid app. Either pay for the app or find the IPA file here: https://iphonecake.com/app_${trackId}_.html"
      exit 1
    fi
  fi

  echo "✅ License exists"

  # Check for existing decrypted files
  # Automatic region changing will be coming eventually, and it will replace some of the code below when it's ready
  decryptedIPA=$(check_files "ipa-files/decrypted" "$bundleId")
  if [[ -n "$decryptedIPA" ]]; then
    transfer_file "$decryptedIPA" "$chatId" "$topicId" "$appInfoResponse"
    echo "⬆️ Starting IPA upload..."
    exit 0
  fi

  # Check for existing downloaded files
  downloadedIPA=$(check_files "ipa-files/encrypted" "$bundleId")
  if [[ $? -eq 1 ]]; then
    echo "✅ Proceeding with the installation."
  else
    humanSize=$(echo "$fileSizeBytes" | awk '{ split( "B KB MB GB TB PB EB ZB YB" , v ); s=1; while( $1>1024 && s<9 ){ $1/=1024; s++ } printf "%.2f %s", $1, v[s] }')
    echo "⬇️ Downloading ${version} ($humanSize)..."
    downloadResponse=$("$ipatool" --keychain-passphrase "$SSH_PASSWORD" --non-interactive download -b "$bundleId" --purchase -o "ipa-files/encrypted" --format json)

    # Log back into iTunes if the session has expired
    if [[ "$downloadResponse" = *"expired"* ]]; then
      loginResponse=$("$ipatool" --keychain-passphrase "$SSH_PASSWORD" --non-interactive auth login -e "$ITUNES_USER" -p "$ITUNES_PASS" --format json)
      if [[ "$loginResponse" != *"success"* ]]; then
        echo "❌ Login to iTunes failed."
        exit 1
      fi
      downloadResponse=$("$ipatool" --keychain-passphrase "$SSH_PASSWORD" --non-interactive download -b "$bundleId" --purchase -o "ipa-files/encrypted" --format json)
    fi

    if [[ "$downloadResponse" = *"error"* ]]; then
      echo "❌ Download of app failed."
      exit 1
    fi

    # JQ is not working with ipatool
    # Example output of downloadResponse:
    # {"level":"info","output":"/Users/mgates/ipastuff/ipa-files/encrypted/com.wms.ecgcases_798663024_5.4.1.ipa","success":true,"time":"2023-06-17T11:20:59-05:00"}
    # downloadedIPA=$(echo "$downloadResponse" | jq 'fromjson | .output')
    # echo "✅ Downloaded app to $downloadedIPA"

    # Verify that the file was downloaded
    downloadedIPA=$(check_files "ipa-files/encrypted" "$bundleId")
    if [[ $? -eq 0 ]]; then
      echo "❌ File not found in the downloads directory."
      exit 1
    fi
  fi

  # Install App
  if ! install_app "$bundleId" "$downloadedIPA"; then
    echo "❌ Failed to install app."
    exit 1
  fi

  # Wait a few seconds after installation to confirm that the app is installed
  if ! ideviceinstaller -l | grep -q "$bundleId"; then
    echo "❌ Failed to install app."
    exit 1
  fi

  # Decrypt App
  echo "🔐 Decrypting app..."
  decrypt_app "$bundleId" "$downloadedIPA"
  if [[ $? -eq 1 ]]; then
    echo "❌ Failed to decrypt app."
    exit 1
  fi

  echo "✅ Decrypted successfully."

  uninstall_app "$bundleId"
  if [[ $? -eq 1 ]]; then
    exit 1
  fi

  # Check for existing decrypted files
  decryptedIPA=$(check_files "ipa-files/decrypted" "$bundleId")
  if [[ $? -eq 1 ]]; then
    transfer_file "$decryptedIPA" "$chatId" "$topicId" "$appInfoResponse"
    echo "⬆️ Starting IPA upload..."
    exit 0
  else
    echo "❌ No decrypted files found for app."
    exit 1
  fi
}

main "$1" "$2" "$3"
