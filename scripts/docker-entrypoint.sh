#!/bin/bash

function check_mandatory_variables() {

	if [ -z "${UPLOAD_BUCKET}" ]
	then
		echo "[ERROR] 'UPLOAD_BUCKET' environment variable is empty"
		exit 1
	fi

	if [ -z "${AWS_ACCESS_KEY_ID}" ]
	then
		echo "[ERROR] 'AWS_ACCESS_KEY_ID' environment variable is empty"
		exit 1
	fi

	if [ -z "${AWS_SECRET_ACCESS_KEY}" ]
	then
		echo "[ERROR] 'AWS_SECRET_ACCESS_KEY' environment variable is empty"
		exit 1
	fi
}


function get_size() {

	if [ -d ${1} ]
	then
		echo "$(du -s "${1}" | cut -f 1)"
	else
		echo "$(wc -c <"${1}")"
	fi
}


function check_paths_to_backup() {

	echo "Checking paths to backup"

	if [ -z "${PATHS_TO_BACKUP}" ]
	then
		echo "[WARN] 'PATHS_TO_BACKUP' environment variable is empty, using root backup path ('${BACKUP_PATH}') instead"
		PATHS_TO_BACKUP="${BACKUP_PATH}"
	fi

	totalSize=0
	for pathToBackup in ${PATHS_TO_BACKUP}
	do
		fullPathToBackup="${BACKUP_PATH}/${pathToBackup}"
		echo "Checking path '${fullPathToBackup}'"
		if [ ! -f ${fullPathToBackup} ] && [ ! -d ${fullPathToBackup} ]
		then
			echo "[ERROR] File or directory not found at '${fullPathToBackup}'"
			exit 1
		fi
		pathSize=$(get_size "${fullPathToBackup}")
		totalSize=$(( totalSize + pathSize ))
		echo "Uncompressed size (bytes): ${pathSize}"
	done

	echo "All paths checked"
	echo "Total uncompressed size (bytes): ${totalSize}"
}


function create_compressed() {

	cd ${BACKUP_PATH}

	echo "Creating backup"
	local startSeconds=${SECONDS}

	tar -czf ${WORK_PATH}/${compressedFilename} ${PATHS_TO_BACKUP}

	compressDurationSeconds=$(( SECONDS - startSeconds ))
	compressedSize=$(get_size "${WORK_PATH}/${compressedFilename}")

	echo "Backup created"
	echo "Compressed size (bytes): ${compressedSize}"
	echo "Compress duration (s): ${compressDurationSeconds}"

	cd - > /dev/null
}


function upload_compressed() {

	local startSeconds=${SECONDS}

	echo -n "Uploading backup to "
	if [ -z ${UPLOAD_ENDPOINT_URL} ]
	then
		echo "S3"
	else
		echo "${UPLOAD_ENDPOINT_URL}"
		endpointUrlOverride="--endpoint-url ${UPLOAD_ENDPOINT_URL}"
	fi

	if aws ${endpointUrlOverride} s3 cp ${WORK_PATH}/${compressedFilename} s3://${UPLOAD_BUCKET} --only-show-errors
	then
		uploadDurationSeconds=$(( SECONDS - startSeconds ))
		echo "Backup uploaded"
		echo "Upload duration (s): ${uploadDurationSeconds}"
	else
		echo "[ERROR] Backup upload failed"
		exit 1
	fi
}


function clean_work_path() {

	echo "Cleaning temporary files"
	rm -f ${WORK_PATH}/*
}


function update_metrics() {

	if [ -z "${PUSHGATEWAY_HOST}" ]
	then
		echo "[WARN] 'PUSHGATEWAY_HOST' environment variable not defined, metrics cannot be published"
		exit 0
	fi

	if [ -z "${PUSHGATEWAY_JOB}" ]
	then
		echo "[ERROR] 'PUSHGATEWAY_JOB' environment variable is empty"
		exit 1
	fi

	PUSHGATEWAY_LABEL=${PUSHGATEWAY_LABEL:-${PUSHGATEWAY_JOB}}
	createdDateSeconds=$(date +%s)

	push_metrics
}


function push_metrics() {

# No indent
cat <<EOF | curl -s --data-binary @- ${PUSHGATEWAY_HOST}/metrics/job/${PUSHGATEWAY_JOB}
# HELP backup_duration_seconds duration of each stage execution in seconds.
# TYPE backup_duration_seconds gauge
backup_duration_seconds{label="${PUSHGATEWAY_LABEL}",stage="compress"} ${compressDurationSeconds:-0}
backup_duration_seconds{label="${PUSHGATEWAY_LABEL}",stage="upload"} ${uploadDurationSeconds:-0}
# HELP backup_duration_seconds_total duration of the script execution in seconds.
# TYPE backup_duration_seconds_total gauge
backup_duration_seconds_total{label="${PUSHGATEWAY_LABEL}"} ${backupDurationSeconds:-0}
# HELP backup_size size of backup in bytes.
# TYPE backup_size gauge
backup_size_bytes{label="${PUSHGATEWAY_LABEL}"} ${compressedSize:-0}
# HELP backup_created_date_seconds created date in seconds.
# TYPE backup_created_date_seconds gauge
backup_created_date_seconds{label="${PUSHGATEWAY_LABEL}"} ${createdDateSeconds}
EOF
}


function main() {

	local startSeconds=${SECONDS}

	check_mandatory_variables

	mkdir -p ${WORK_PATH}

	check_paths_to_backup

	nowDate=$(date +%Y-%m-%d_%H-%M-%S)
	compressedFilename="${nowDate}-backup.tar.gz"

	create_compressed
	upload_compressed
	clean_work_path

	backupDurationSeconds=$(( SECONDS - startSeconds ))

	update_metrics

	echo "Backup process ended successfully"
}

main
