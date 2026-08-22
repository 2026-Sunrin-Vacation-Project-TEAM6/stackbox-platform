FROM alpine:3.20

RUN apk add --no-cache curl

WORKDIR /app

COPY smoke_test.sh .
RUN chmod +x smoke_test.sh

CMD ["./smoke_test.sh"]
