import os
import urllib.parse
import boto3
import csv


def lambda_handler(event, _):
    orders_data_key = "orders"
    customers_data_key = "customers"
    items_data_key = "items"

    bucket = event['Records'][0]['s3']['bucket']['name']
    key = urllib.parse.unquote_plus(event['Records'][0]['s3']['object']['key'], encoding='utf-8')
    print("bucket: " + bucket + " key: " + key)

    key_parts = key.split("_")
    if len(key_parts) != 2:
        raise ValueError("invalid file name")

    file_key = key_parts[0]
    date = key_parts[1]
    if file_key not in [orders_data_key, customers_data_key, items_data_key]:
        raise ValueError("invalid file type")

    s3_resource = boto3.resource('s3')
    try:
        orders_file_name = f"{orders_data_key}_{date}"
        customers_file_name = f"{customers_data_key}_{date}"
        items_file_name = f"{items_data_key}_{date}"
        print(f"Getting object {orders_file_name} from S3")
        orders_s3_object = s3_resource.Object(bucket, orders_file_name)
        print(f"Getting object {customers_file_name} from S3")
        customers_s3_object = s3_resource.Object(bucket, customers_file_name)
        print(f"Getting object {items_file_name} from S3")
        items_s3_object = s3_resource.Object(bucket, items_file_name)
        print("Got all objects from S3")

        print(f"Getting content of {orders_file_name} from S3")
        orders_data = orders_s3_object.get()['Body'].read().decode('utf-8').splitlines()
        print(f"Getting content of {customers_file_name} from S3")
        customers_data = customers_s3_object.get()['Body'].read().decode('utf-8').splitlines()
        print(f"Getting content of {items_file_name} from S3")
        items_data = items_s3_object.get()['Body'].read().decode('utf-8').splitlines()
        print("Read all file contents")

        efs_path = "/mnt/files"
        files = os.listdir(efs_path)
        print(f"Before files in {efs_path}: {files}")
        orders_file = open(f'{efs_path}/{orders_data_key}_{date}.csv', "w")
        customers_file = open(f'{efs_path}/{customers_data_key}_{date}.csv', "w")
        items_file = open(f'{efs_path}/{items_data_key}_{date}.csv', "w")

        # Generate Messages
        orders = {}
        messages = {}
        lines = csv.reader(customers_data)
        headers = next(lines)
        print(f'customers_data headers: {headers}')
        customers_file.write(",".join(headers))
        for line in lines:
            customers_file.write(",".join(line))
            if len(line) != 5:
                # TODO: Error message
                continue
            messages[line[3]] = {
                "type": "customer_message",
                "customer_reference": line[3],
                "number_of_orders": 0,
                "total_amount_spent": 0
            }
        customers_file.close()

        lines = csv.reader(orders_data)
        headers = next(lines)
        print(f'orders_data headers: {headers}')
        orders_file.write(",".join(headers))
        for line in lines:
            orders_file.write(",".join(line))
            if len(line) != 5:
                # TODO: Error message
                continue
            orders[line[3]] = {
                "customer_ref": line[1],
                "total_amount": 0
            }
        orders_file.close()

        lines = csv.reader(items_data)
        headers = next(lines)
        print(f'items_data headers: {headers}')
        items_file.write(",".join(headers))
        for line in lines:
            items_file.write(",".join(line))
            if len(line) != 5:
                # TODO: Error message
                continue
            orders[line[1]]["total_amount"] += float(line[4])
        items_file.close()

        for order_key in orders:
            messages[orders[order_key]["customer_ref"]]["number_of_orders"] += 1
            messages[orders[order_key]["customer_ref"]]["total_amount_spent"] += orders[order_key]["total_amount"]

        sqs = boto3.client('sqs',
                           region_name='eu-central-1',
                           aws_access_key_id='',
                           aws_secret_access_key='')
        for message_key in messages:
            print("Sending message to SQS: ", messages[message_key])
            sqs.send_message(
                QueueUrl="https://sqs.eu-central-1.amazonaws.com/515662235425/output-queue",
                MessageBody=str(messages[message_key])
            )

        files = os.listdir(efs_path)
        print(f"After files in {efs_path}: {files}")
    except Exception as e:
        print(e)
        print('Error getting object {} from bucket {}.'.format(key, bucket))
        raise e
