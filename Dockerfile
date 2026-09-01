# ---- Build stage ----
FROM node:20-alpine AS build
WORKDIR /build
COPY package.json package-lock.json ./
RUN npm install
COPY . .
# NOTE: uses the "development" config on purpose here so the bundled app
# points at http://localhost:9000/app (environment.ts), matching the
# docker-compose port mapping for local testing. For a real AWS deploy,
# build with --configuration production instead (see README.md).
RUN npm run build -- --configuration development

# ---- Runtime stage (nginx) ----
# Note: in AWS this project deploys the built dist/ to S3 + CloudFront
# (see README.md). This Dockerfile is provided for local/docker-compose
# testing so you can preview the production build without S3.
FROM nginx:alpine
COPY --from=build /build/dist/frontend/browser /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
