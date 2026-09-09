DART_FILE="lib/env.dart"

if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is required but not installed. Install it using 'sudo apt install jq' or 'brew install jq'."
    exit 1
fi

dart run build_runner build --define flutter_secure_dotenv_generator:flutter_secure_dotenv=OUTPUT_FILE=encryption_key.json

if [ ! -f "encryption_key.json" ]; then
    echo "Error: JSON file encryption_key.json not found."
    exit 1
fi

if [ ! -f "$DART_FILE" ]; then
    echo "Error: Env dart file not found."
    exit 1
fi

ENCRYPTION_KEY=$(jq -r '.ENCRYPTION_KEY' 'encryption_key.json')
IV_VALUE=$(jq -r '.IV' 'encryption_key.json')

if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS requires an empty string '' for the -i flag
    sed -i '' "s|static const _encryptionKey = '.*';|static const _encryptionKey = '$ENCRYPTION_KEY';|" "$DART_FILE"
    sed -i '' "s|static const _iv = '.*';|static const _iv = '$IV_VALUE';|" "$DART_FILE"
else
    # Linux
    sed -i "s|static const _encryptionKey = '.*';|static const _encryptionKey = '$ENCRYPTION_KEY';|" "$DART_FILE"
    sed -i "s|static const _iv = '.*';|static const _iv = '$IV_VALUE';|" "$DART_FILE"
fi

rm encryption_key.json

echo "Env updated"