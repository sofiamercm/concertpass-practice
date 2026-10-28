# Concertpass - Deployment and Load Testing Report

## 1. Objective

The objective was to deploy a cloud-based concert reservation system that processes reservation requests asynchronously and prevents ticket sales from exceeding configured capacity.

## 2. Architecture

The application runs on Amazon EKS and consists of `ticket-api`, `ticket-worker`, and `ticket-checkout`. Amazon SQS FIFO is used for asynchronous message processing, DynamoDB stores concert information and ticket capacities, Amazon RDS PostgreSQL stores reservations, and Amazon ECR stores container images.

The final runtime evidence records two EKS nodes in the `Ready` state. The API and checkout deployments each had one available replica, and the worker deployment had three available replicas.

## 3. Reservation Flow

The API accepts reservation requests and creates records with an initial `pending` status. Requests are submitted to SQS FIFO for asynchronous processing. The worker checks ticket availability and updates reservation records to `confirmed` or `rejected`.

A demonstrated reservation returned HTTP 202 with status `pending`. A subsequent GET request returned HTTP 200 with status `confirmed`. The reservation identifier and both responses are saved in the `evidence/` directory.

The direct SQS message capture attempt returned no visible message, so the saved empty JSON file does not establish receipt of that individual message. The FIFO queue configuration and the application code that submits messages were inspected separately.

## 4. Infrastructure and Data Evidence

The saved evidence includes:

- EKS node and deployment status.
- Kubernetes deployment and service details.
- ECR image references and Kubernetes manifest information.
- DynamoDB concert records and table schema.
- RDS reservation schema and grouped reservation-status counts.
- SQS FIFO queue attributes.
- Runtime responses and load-test results.

The SQS queue was verified as FIFO with a 60-second visibility timeout. The worker source code was inspected for transaction locking and reservation status updates.

## 5. Test Results

| Test | Requests | Confirmed | Rejected | Additional result |
|---|---:|---:|---:|---|
| Basic reservation flow | 1 | 1 | 0 | Reservation later confirmed |
| Small load test | 5 | Not separately counted | Not separately counted | 5 HTTP 202 responses; 0 transport errors |
| High-demand test | 30 | 10 | 20 | VIP capacity limit reached |
| Scale test | 80 | 50 | 30 | 3 worker replicas |
| Additional async-flow test | 1 | 1 | 0 | HTTP 202 pending, followed by HTTP 200 confirmed |

The high-demand and scale-test results match the configured VIP capacities in those scenarios. RDS grouped counts provide additional evidence of confirmed and rejected reservations. These results support capacity enforcement for the tested workloads; they do not establish behavior for every possible workload.

## 6. Checkout Verification

The checkout endpoint was tested directly with a valid reservation identifier and quantity. It returned HTTP 200 with status `authorized`.

This confirms the endpoint's tested authorization response. It does not represent a real payment, and the independent endpoint test alone does not prove that the worker invoked checkout as part of each reservation transaction.

## 7. Evidence Files

The `evidence/` directory contains deployment and runtime captures, DynamoDB records and schema, RDS schema and status counts, SQS queue attributes, load-test results, and reservation responses.

The direct SQS message capture file is empty because the receive operation returned no visible message. This limitation should be disclosed if direct message-level evidence is required.

## 8. Conclusion and Remaining Work

The recorded tests demonstrate successful asynchronous reservation processing and capacity enforcement under the tested workloads. The final runtime capture confirms two Ready EKS nodes and available API, checkout, and worker deployments.

Before final submission:
1. Verify the repository contents and Git push status.
2. Review the assignment rubric for any required screenshots or additional evidence.
3. Record the demonstration video, showing the infrastructure, database evidence, and reservation/load-test results.
4. Verify the teardown procedure and save all evidence before deleting cloud resources.

The teardown script has not been run as part of this report preparation.
