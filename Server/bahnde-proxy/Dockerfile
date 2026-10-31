FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY proxy.py tzlog.py ./
RUN mkdir /data && chown nobody /data
USER nobody
ENV TZ_DB=/data/tz.db
VOLUME /data
ENV PORT=8080
EXPOSE 8080
CMD ["python", "proxy.py"]
