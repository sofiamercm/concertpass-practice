# Concertpass

Concertpass is a cloud-based concert reservation system deployed on Amazon EKS. It uses asynchronous processing to handle ticket reservations and enforce ticket capacity.

## Architecture

- Amazon EKS runs the application workloads on two worker nodes.
- `ticket-api` exposes reservation endpoints through a Kubernetes NodePort service.
- Amazon SQS FIFO queues reservation requests for asynchronous processing.
- `ticket-worker` processes reservation messages and checks ticket availability.
- Amazon DynamoDB stores concert information and ticket capacities.
- Amazon RDS PostgreSQL stores reservation records and their statuses.
- `ticket-checkout` provides a checkout authorization endpoint.
- Amazon ECR stores the container images.

## API Endpoints

- `POST /reserve`: submits a reservation request and returns its identifier and initial status.
- `GET /reservation/{reservation_id}`: retrieves a reservation and its current status.
- `GET /health`: checks checkout service health.
- `POST /checkout`: validates checkout data and returns an authorization response.

The reservation API is exposed through Kubernetes NodePort `30080`. A local port-forward can also be used for testing.

## Reservation Processing

The API creates a reservation with an initial `pending` status and submits it for asynchronous processing. The worker checks ticket availability and updates the reservation to `confirmed` or `rejected`.

The worker uses PostgreSQL transaction locking to coordinate concurrent capacity checks. The load tests recorded no overselling in the tested scenarios.

The checkout endpoint was tested independently and returned `authorized` for a valid request. This response represents checkout authorization in the application; it does not establish that a real payment was processed.

## Test Results

The `evidence/` directory contains deployment, database, runtime, and load-test evidence.

- Basic reservation flow: a reservation was created and later confirmed.
- Small load test: 5 requests, 5 HTTP 202 responses, and 0 transport errors.
- High-demand test: 30 requests, 10 confirmed, and 20 rejected.
- Scale test: 80 requests with 3 worker replicas, 50 confirmed, and 30 rejected.
- Additional asynchronous-flow test: a POST returned HTTP 202 with `pending`; a subsequent GET returned HTTP 200 with `confirmed`.

The direct SQS message capture attempt did not return a visible message. The FIFO queue configuration and application code were inspected separately, but the empty capture file is not proof of an individual message being received from the queue.

## Project Structure

- `ticket-api/`: reservation API.
- `ticket-worker/`: asynchronous reservation processing.
- `ticket-checkout/`: checkout authorization service.
- `k8s/`: Kubernetes manifests.
- `scripts/`: project setup and teardown scripts.
- `tests/`: reservation and load tests.
- `evidence/`: deployment, runtime, database, and load-test evidence.

## Deployment Notes

The project uses AWS resources in `us-east-1`. Deployment requires valid AWS credentials, Kubernetes access, and the configured infrastructure.

Review `scripts/setup.sh` before running it. The teardown script deletes resources and should only be run after all required evidence, report files, and video recordings have been saved.
