from flask import Flask, request
import requests

app = Flask(__name__)

NTFY_URL = "http://ntfy:80/homelab-alerts-kagwj"

@app.route("/alert", methods=["POST"])
def handle_alert():
    data = request.get_json()
    print("RECEIVED DATA:", data, flush=True)

    for alert in data.get("alerts", []):
        summary = alert.get("annotations", {}).get("summary", "Alert fired")
        description = alert.get("annotations", {}).get("description", "")
        status = alert.get("status", "unknown")

        message = f"[{status.upper()}] {summary}\n{description}"
        print("SENDING TO NTFY:", message, flush=True)

        r = requests.post(NTFY_URL, data=message.encode("utf-8"))
        print("NTFY RESPONSE:", r.status_code, r.text, flush=True)

    return "ok", 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
