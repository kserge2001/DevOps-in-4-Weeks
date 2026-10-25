FROM python:3.14-slim

# Lets the same image run on Lambda: the adapter turns Lambda events into HTTP requests.
# On EC2, ECS and EKS it does nothing.
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0 /lambda-adapter /opt/extensions/lambda-adapter

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py index.html ./

ENV PORT=8080
EXPOSE 8080
USER 1000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
