FROM python:3.12-slim
WORKDIR /app
COPY relay.py .
RUN pip install flask requests
CMD ["python", "relay.py"]
