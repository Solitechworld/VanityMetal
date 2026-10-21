FROM swift:5.10-jammy
RUN apt-get update && apt-get install -y python3 python3-pytest && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . .
CMD ["python3", "-m", "pytest", "tests/", "-q"]
