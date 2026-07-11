#!/bin/bash
# Script executado automaticamente pelo LocalStack após inicialização

echo ">>> Criando recursos AWS locais no LocalStack..."

# Cria a fila SQS
awslocal sqs create-queue \
  --queue-name togglemaster-events \
  --region us-east-1

# Cria a tabela DynamoDB para o analytics-service
awslocal dynamodb create-table \
  --table-name analytics-events \
  --attribute-definitions AttributeName=event_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1

echo ">>> LocalStack: SQS queue 'togglemaster-events' e DynamoDB table 'analytics-events' criados."
