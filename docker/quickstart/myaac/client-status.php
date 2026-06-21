<?php

declare(strict_types=1);

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

try {
	$request = json_decode(file_get_contents('php://input') ?: '{}', true);
	$requestType = is_array($request) ? ($request['type'] ?? '') : '';

	if ($requestType === 'eventschedule') {
		$eventFile = '/canary/events.json';
		$eventData = is_file($eventFile)
			? json_decode(file_get_contents($eventFile) ?: '{}', true, 512, JSON_THROW_ON_ERROR)
			: [];
		$events = [];

		foreach ($eventData['events'] ?? [] as $event) {
			$start = DateTimeImmutable::createFromFormat('!m/d/Y', (string) ($event['startdate'] ?? ''));
			$end = DateTimeImmutable::createFromFormat('!m/d/Y', (string) ($event['enddate'] ?? ''));
			if (!$start || !$end) {
				continue;
			}

			$colors = $event['colors'] ?? [];
			$details = $event['details'] ?? [];
			$events[] = [
				'name' => (string) ($event['name'] ?? 'Unnamed Event'),
				'description' => (string) ($event['description'] ?? ''),
				'startdate' => $start->getTimestamp(),
				'enddate' => $end->setTime(23, 59, 59)->getTimestamp(),
				'colordark' => (string) ($colors['colordark'] ?? '#303030'),
				'colorlight' => (string) ($colors['colorlight'] ?? '#606060'),
				'displaypriority' => (int) ($details['displaypriority'] ?? 5),
				'isseasonal' => (int) ($details['isseasonal'] ?? 0),
				'specialevent' => (int) ($details['specialevent'] ?? 0),
			];
		}

		echo json_encode([
			'lastupdatetimestamp' => time(),
			'eventlist' => $events,
		], JSON_THROW_ON_ERROR);
		exit;
	}

	$host = getenv('CANARY_DB_HOST') ?: 'db';
	$port = getenv('CANARY_DB_PORT') ?: '3306';
	$database = getenv('CANARY_DB_NAME') ?: 'canary';
	$user = getenv('CANARY_DB_USER') ?: 'canary';
	$password = getenv('CANARY_DB_PASSWORD') ?: 'canary';

	$pdo = new PDO(
		"mysql:host={$host};port={$port};dbname={$database};charset=utf8mb4",
		$user,
		$password,
		[
			PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
			PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
		]
	);

	$creature = $pdo->query('SELECT `raceid` FROM `boosted_creature` LIMIT 1')->fetch();
	$boss = $pdo->query('SELECT `raceid` FROM `boosted_boss` LIMIT 1')->fetch();

	echo json_encode([
		'creatureraceid' => isset($creature['raceid']) ? (int) $creature['raceid'] : 0,
		'bossraceid' => isset($boss['raceid']) ? (int) $boss['raceid'] : 0,
	], JSON_THROW_ON_ERROR);
} catch (Throwable $exception) {
	http_response_code(503);
	echo json_encode([
		'errorMessage' => 'Boosted creature data is unavailable.',
		'errorCode' => 503,
	], JSON_THROW_ON_ERROR);
}
