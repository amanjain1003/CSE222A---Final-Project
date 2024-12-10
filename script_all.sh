#!/bin/bash

# Configuration
SERVER_IP=54.200.191.248
TRIALS=5
OUTPUT_DIR="./results"
DELAY_MS=20
PACKET_LOSS_RATES=("0%" "0.005%" "0.01%")
CCA_MODES=("cubic" "bbr")
APPLICATION_MODES=("http" "iperf3")
IPERF_DURATION=10                 # Duration of iperf3 tests in seconds
CWND_LOG_INTERVAL=0.1             # Interval for logging cwnd and ssthresh

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Function to set congestion control algorithm
set_cca() {
    local cca=$1
    echo "Setting congestion control algorithm to $cca..."
    sudo sysctl -w net.ipv4.tcp_congestion_control="$cca" > /dev/null
    CURRENT_CCA=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    echo "Current CCA: $CURRENT_CCA"
}

# Function to compute means
compute_means() {
    local file=$1
    local column=$2
    awk -F ',' -v col="$column" 'NR > 1 {sum += $col; count++} END {if (count > 0) print sum / count; else print 0}' "$file"
}

# Loop over CCAs and Packet Loss Rates
for cca in "${CCA_MODES[@]}"; do
    for loss_rate in "${PACKET_LOSS_RATES[@]}"; do
        echo "Running tests with CCA=$cca and Packet Loss=$loss_rate..."

        # Set the congestion control algorithm
        set_cca "$cca"

        # Apply network conditions
        echo "Applying $DELAY_MS ms delay and $loss_rate packet loss..."
        #sudo tc qdisc del dev enX0 root
        sudo tc qdisc add dev enX0 root netem delay "${DELAY_MS}ms" loss "$loss_rate"

        # Measure RTT
        echo "Measuring RTT..."
        ping -c 10 "$SERVER_IP" > "$OUTPUT_DIR/rtt.txt"
        AVG_RTT=$(grep "rtt" "$OUTPUT_DIR/rtt.txt" | awk -F '/' '{print $5}')
        echo "Average RTT: $AVG_RTT ms"


        # Output files for this configuration
        CURL_FILE="$OUTPUT_DIR/curl_${cca}_${loss_rate}.txt"
        IPERF_FILE="$OUTPUT_DIR/iperf_${cca}_${loss_rate}.txt"

        echo "Trial,Throughput(Bytes/sec),FCT(sec)" > "$CURL_FILE"
        echo "Trial,Throughput(Mbps)" > "$IPERF_FILE"

        # Loop for trials
        for ((i = 1; i <= TRIALS; i++)); do
            echo "Trial $i for CCA=$cca and Packet Loss=$loss_rate..."

            if [ "$i" -eq 1 ]; then
                # Start logging cwnd and ssthresh in the background
                CWND_LOG="$OUTPUT_DIR/cwnd_${cca}_${loss_rate}_CURL.txt"
                echo "Logging cwnd and ssthresh..."
                (
                    while true; do
                        ss -ein dst "$SERVER_IP" | tail -1 | grep -oE 'cwnd:[0-9]+ ssthresh:[0-9]+' >> "$CWND_LOG"
                        sleep "$CWND_LOG_INTERVAL"
                    done
                ) &
                CWND_LOG_PID=$!
            fi

            # Run curl test
            OUTPUT=$(curl -o /dev/null -s -w "Throughput: %{speed_download} bytes/sec, FCT: %{time_total} seconds\n" http://$SERVER_IP/index.html)
            THROUGHPUT=$(echo "$OUTPUT" | awk -F ',' '{print $1}' | awk '{print $2}')
            FCT=$(echo "$OUTPUT" | awk -F ',' '{print $2}' | awk '{print $2}')
            echo "$i,$THROUGHPUT,$FCT" >> "$CURL_FILE"

            # Stop logging cwnd and ssthresh
            if [ "$i" -eq 1 ]; then            
                kill "$CWND_LOG_PID"
                wait "$CWND_LOG_PID" 2>/dev/null	    # Start logging cwnd and ssthresh in the background
            fi


            if [ "$i" -eq 1 ]; then
                # Start logging cwnd and ssthresh in the background
                CWND_LOG="$OUTPUT_DIR/cwnd_${cca}_${loss_rate}_IPERF.txt"
                echo "Logging cwnd and ssthresh..."
                (
                    while true; do
                        ss -ein dst "$SERVER_IP" | tail -1 | grep -oE 'cwnd:[0-9]+ ssthresh:[0-9]+' >> "$CWND_LOG"
                        sleep "$CWND_LOG_INTERVAL"
                    done
                ) &
                CWND_LOG_PID=$!
            fi

            # Run iperf3 test
            echo "Running iperf3..."
            IPERF_OUTPUT=$(iperf3 -c $SERVER_IP -n "0.1G" --json)
            IPERF_THROUGHPUT=$(echo "$IPERF_OUTPUT" | jq '.end.sum_sent.bits_per_second' | awk '{print $1/1000000}') # Convert to Mbps
            FCT=$(echo "$IPERF_OUTPUT" | jq '.end.sum_sent.seconds') # Extract FCT in seconds
            echo "$i,$IPERF_THROUGHPUT,$FCT" >> "$IPERF_FILE"

            # Stop logging cwnd and ssthresh
            if [ "$i" -eq 1 ]; then            
                kill "$CWND_LOG_PID"
                wait "$CWND_LOG_PID" 2>/dev/null	    # Start logging cwnd and ssthresh in the background
            fi

        done

        echo "Results for CCA=$cca and Packet Loss=$loss_rate saved to $OUTPUT_DIR."


        # Calculate and print mean throughput, FCT, and RTT
        MEAN_THROUGHPUT=$(compute_means "$CURL_FILE" 2)
        MEAN_FCT=$(compute_means "$CURL_FILE" 3)
        MEAN_RTT=$AVG_RTT
        MEAN_IPERF_THROUGHPUT=$(compute_means "$IPERF_FILE" 2)
        MEAN_IPERF_FCT=$(compute_means "$IPERF_FILE" 3)

        echo "Mean Throughput (Bytes/sec): $MEAN_THROUGHPUT"
        echo "Mean FCT (sec): $MEAN_FCT"
        echo "Mean RTT (ms): $MEAN_RTT"
        echo "Mean iperf3 Throughput (Mbps): $MEAN_IPERF_THROUGHPUT"
        echo "Mean iperf3 FCT (sec): $MEAN_IPERF_FCT"
        echo "Removing simulated network conditions..."

        sudo tc qdisc del dev enX0 root
    done
done

echo "All tests completed. Results are saved in $OUTPUT_DIR."
