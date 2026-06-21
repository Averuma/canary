<?php

declare(strict_types=1);

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

try {
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
