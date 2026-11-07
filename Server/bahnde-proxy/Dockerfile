FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY proxy.py .
# The coach-sequence portal's log (REGIO_LOG), kept in a volume.
RUN mkdir logs && chown nobody logs
USER nobody
ENV PORT=8080
EXPOSE 8080
CMD ["python", "proxy.py"]
