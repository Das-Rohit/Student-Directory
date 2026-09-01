# Student Directory — Microservices + Angular

A full-stack "Project One" style build: a Spring Boot microservice backed by
MySQL, and an Angular front end that lists/creates/edits/deletes students.
Structured so it can run locally in Docker, or be deployed to AWS using the
same architecture described in the walkthrough this was built from:
ECS/Fargate + ALB + RDS on the backend, and S3 + CloudFront on the front end.

```
project/
├── backend/     Spring Boot microservice (Java 17, Maven, MySQL)
├── frontend/    Angular app (standalone components, HttpClient)
└── docker-compose.yml   Runs mysql + backend + frontend together locally
```

## Run it locally (fastest path)

Requires Docker + Docker Compose.

```bash
docker compose up --build
```

- Frontend: http://localhost:8080
- Backend API: http://localhost:9000/app/students
- MySQL: localhost:3306 (db `student`, user `root`, password `password`)

The frontend container is built against `environment.ts` (development), which
points at `http://localhost:9000/app`, matching the port Compose exposes.

To stop and wipe the database volume:

```bash
docker compose down -v
```

## Run it locally without Docker

**Backend** (needs Java 17 + Maven, and a MySQL instance):

```bash
cd backend
# point at your local MySQL, e.g.:
export DB_HOST=localhost DB_PORT=3306 DB_NAME=student DB_USERNAME=root DB_PASSWORD=yourpassword
mvn spring-boot:run
```

The service listens on port `9000` with context path `/app`, so:
- `GET  http://localhost:9000/app/students` — list all
- `GET  http://localhost:9000/app/student/{id}` — get one
- `POST http://localhost:9000/app/students` — create `{ "name": "Akshay" }`
- `PUT  http://localhost:9000/app/student/{id}` — update
- `DELETE http://localhost:9000/app/student/{id}` — delete
- `GET  http://localhost:9000/app/actuator/health` — health check (used as the ALB target-group health check path in AWS)

The table itself is auto-created on startup (`spring.jpa.hibernate.ddl-auto=update`).
`backend/src/main/resources/data-sample.sql` mirrors the manual `mysql` CLI
steps from the walkthrough if you want to seed data by hand instead.

**Frontend** (needs Node 20+):

```bash
cd frontend
npm install
npm start        # ng serve, http://localhost:4200, talks to localhost:9000/app
```

## Deploying to AWS (matches the architecture in the walkthrough)

This mirrors the environment naming and component choices from the recorded
session (`dev` environment, domain `zeroinitiative.com` used as an example —
swap in your own domain throughout).

### Backend: RDS → ECS (Fargate) → ALB → Route 53

1. **RDS (MySQL)**
   - Create a MySQL RDS instance (e.g. `student-db-dev`), ideally in a
     private subnet.
   - Create the `student` database (the app will create the `student` table
     itself via JPA `ddl-auto=update`, or run `data-sample.sql` by hand).
   - In Route 53, create a friendly CNAME/alias for the RDS endpoint, e.g.
     `studentdb-dev.zeroinitiative.com`, instead of using the
     auto-generated RDS hostname.

2. **Containerize and push to ECR**
   ```bash
   cd backend
   docker build -t student .
   docker tag student:latest <account-id>.dkr.ecr.<region>.amazonaws.com/student:latest
   aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin <account-id>.dkr.ecr.<region>.amazonaws.com
   docker push <account-id>.dkr.ecr.<region>.amazonaws.com/student:latest
   ```

3. **ECS cluster + service (Fargate or EC2)**
   - Create a cluster, task definition (container port `9000`), and service
     (`student-service`), spread across two AZs as shown in the walkthrough.
   - Set task environment variables: `DB_HOST`, `DB_PORT`, `DB_NAME`,
     `DB_USERNAME`, `DB_PASSWORD` (use Secrets Manager / SSM Parameter Store
     for the password rather than plaintext).

4. **Application Load Balancer**
   - Target group `student-service-tg`, health check path
     `/app/actuator/health` (Spring Boot Actuator, already on the classpath).
   - Attach an ACM certificate to the ALB listener (443) and redirect HTTP → HTTPS.
   - In Route 53, alias a record (e.g. `api-student.zeroinitiative.com`) to
     the ALB.

5. **Auto Scaling** — attach an Auto Scaling policy to the ECS service so it
   maintains desired task count / scales under load, as demonstrated in the
   walkthrough (kill a task and watch it respawn).

### Frontend: Angular → S3 → CloudFront → Route 53

1. Update `frontend/src/environments/environment.prod.ts` with your real ALB
   domain, e.g. `https://api-student.zeroinitiative.com/app`.
2. Build for production:
   ```bash
   cd frontend
   npm install
   npm run build -- --configuration production
   ```
3. Upload the contents of `dist/frontend/browser/` to an S3 bucket
   (private — no public access).
4. Create a CloudFront distribution with:
   - Origin = the S3 bucket, using an **Origin Access Identity (OAI)** so the
     bucket policy only allows `GetObject` from CloudFront (never directly
     from the S3 endpoint).
   - Default root object `index.html`.
   - Redirect HTTP → HTTPS.
   - Attach an ACM certificate for your custom domain (e.g.
     `frontend-dev.zeroinitiative.com`).
5. In Route 53, create an alias record pointing your domain at the
   CloudFront distribution.
6. CloudFront ships with **Shield Standard** for baseline DDoS mitigation;
   add a **WAF** Web ACL on the distribution for extra protection if needed.

### Security notes carried over from the walkthrough

- Keep the RDS instance and (optionally) the ECS tasks in private subnets.
- Encrypt data at rest (RDS storage encryption) and in transit (ACM/SSL on
  both the ALB and CloudFront).
- Only allow the S3 bucket to be read via CloudFront's Origin Access
  Identity — block all direct public access to the bucket.
- Tighten the backend's `@CrossOrigin(origins = "*")` in
  `StudentController` to your actual frontend domain before going to
  production.
- Consider a CI/CD pipeline (e.g. CodePipeline/CodeBuild or GitHub Actions)
  that builds and pushes a new image on every commit, then updates the ECS
  service — the "DevOps cycle" improvement mentioned at the end of the
  walkthrough.

### Environments

Replicate the same stack per environment (`dev`, `qa`, `stage`, `prod`) by
changing the `-dev` suffix in domain names and using separate ECS
services/RDS instances (or just `dev` → `prod` if you want to keep costs
down), exactly as discussed in the recording.

## Tearing it down (AWS)

To avoid ongoing cost: delete the ECS service/cluster first (this also
removes the associated Auto Scaling group/launch config/EC2 instances if
you used EC2-backed capacity), then delete the RDS instance (skip the final
snapshot if you don't need it), then remove the CloudFront distribution, S3
bucket, and Route 53 records.
